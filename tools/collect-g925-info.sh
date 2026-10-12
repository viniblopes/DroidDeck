#!/usr/bin/env bash
# Read-only Android diagnostics. All report files are written on the host.
set -eu
command -v python3 >/dev/null 2>&1 || {
  echo 'Erro: Python 3 precisa estar instalado no computador.' >&2
  exit 2
}
exec python3 - "$@" <<'PY'
import argparse
import collections
import csv
import datetime
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import time

if sys.version_info < (3, 8):
    print("Erro: Python 3.8 ou mais recente é necessário no computador.", file=sys.stderr)
    sys.exit(2)

OUTPUT_LIMIT = 4 * 1024 * 1024
FILE_LIMIT = 64 * 1024
GPU_WORDS = re.compile(r"mali|kbase|csf|gpu|firmware|memory[_ -]?groups?|^ged$", re.I)
PROP_WORDS = re.compile(r"mali|kbase|csf|gpu|vulkan|graphics|gralloc|egl|gles", re.I)
LOG_WORDS = re.compile(r"mali|kbase|csf|gpu|vulkan|firmware|dma.?buf|gralloc|avc:.*denied", re.I)
# Only informational attributes are read; all other discovered entries are inventory only.
INFO_NAMES = set("""
gpuinfo gpu_id gpu_model product_id gpu_revision revision core_mask shader_present
l2_present core_features tiler_features mem_features mmu_features coherency_mode
version srcversion driver_version kbase_version uapi_version csf_version
firmware_version fw_version fw_name memory_groups num_groups group_count
shader_core_count shader_core_mask compression_backend large_page_conf
""".split())
INFO_DIRS = {"device", "parameters", "firmware_config", "memory_groups", "csf", "hal"}


def run_process(argv, timeout, limit=OUTPUT_LIMIT):
    """Drain both pipes with a shared storage cap and a host process-group deadline."""
    start = time.monotonic()
    chunks = {"stdout": bytearray(), "stderr": bytearray()}
    seen = {"stdout": 0, "stderr": 0}
    timed_out = False
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            for name in chunks:
                stream = getattr(process, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map() or process.poll() is None:
                if time.monotonic() - start >= timeout:
                    timed_out = True
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    break
                for key, _ in selector.select(0.1):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    name = key.data
                    seen[name] += len(data)
                    # Reserve stderr space so a verbose stdout cannot erase permission errors.
                    stderr_limit = min(FILE_LIMIT, limit // 2)
                    stream_limit = stderr_limit if name == "stderr" else limit - stderr_limit
                    room = max(0, stream_limit - len(chunks[name]))
                    chunks[name].extend(data[:room])
        process.wait()
    finally:
        # Also clean up descendants if ADB exits while one still owns a pipe.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()
        process.stderr.close()
    return dict(argv=argv, exit_code=process.returncode, timed_out=timed_out,
                duration=time.monotonic() - start,
                stdout=bytes(chunks["stdout"]), stderr=bytes(chunks["stderr"]),
                truncated=any(seen[k] > len(chunks[k]) for k in seen))


def text(result, stream="stdout"):
    return result[stream].decode("utf-8", errors="replace")


def status(result):
    if result["timed_out"] or result["exit_code"] in (124, 137):
        return "timeout"
    if re.search(r"permission denied|operation not permitted|access denied", text(result, "stderr"), re.I):
        return "não acessível"
    if result["exit_code"] != 0:
        return "não coletado"
    if result["truncated"]:
        return "truncado"
    return "observado"


def filtered_logs(raw):
    lines = raw.decode("utf-8", errors="replace").splitlines()
    keep = set()
    for i, line in enumerate(lines):
        if LOG_WORDS.search(line):
            keep.update(range(max(0, i - 2), min(len(lines), i + 3)))
    return ("\n".join(lines[i] for i in sorted(keep)) + "\n").encode("utf-8")


class Collector:
    def __init__(self, adb, serial, output, timeout):
        self.adb, self.serial, self.output, self.timeout = adb, serial, output, timeout
        self.remote_timeout = False
        self.results = {}
        self.notes = []

    def save(self, name, result):
        self.results[name] = result
        for stream in ("stdout", "stderr"):
            (self.output / (name + "." + stream + ".txt")).write_bytes(result[stream])
        metadata = (
            "command=" + shlex.join(result["argv"]) + "\n"
            + "exit_code=" + str(result["exit_code"]) + "\n"
            + "duration_seconds=%.3f\n" % result["duration"]
            + "host_timeout=" + str(result["timed_out"]) + "\n"
            + "truncated=" + str(result["truncated"]) + "\n"
            + "status=" + status(result) + "\n"
        )
        (self.output / (name + ".command.txt")).write_text(metadata, encoding="utf-8")
        return result

    def query(self, name, command, seconds=None, file_read=False):
        seconds = self.timeout if seconds is None else min(seconds, self.timeout)
        remote = command
        if self.remote_timeout:
            remote = "toybox timeout -k 1 %s sh -c %s" % (seconds, shlex.quote(command))
        result = run_process([self.adb, "-s", self.serial, "shell", remote], seconds + 3)
        if file_read and len(result["stdout"]) >= FILE_LIMIT:
            result["stdout"] = result["stdout"][:FILE_LIMIT]
            result["truncated"] = True
        return self.save(name, result)

    def read_file(self, name, path):
        return self.query(name, "head -c %d %s" % (FILE_LIMIT, shlex.quote(path)),
                          seconds=5, file_read=True)

    def collect(self):
        probe = self.query("toybox-timeout", "toybox timeout -k 1 1 true", seconds=5)
        self.remote_timeout = probe["exit_code"] == 0 and not probe["timed_out"]
        for name, command in (
            ("getprop", "getprop"), ("identity", "id"), ("selinux-context", "id -Z"),
            ("selinux", "getenforce"), ("kernel", "uname -a"),
            ("mali-node", "ls -ldZ /dev/mali0"),
            ("dma-heaps", "ls -ldZ /dev/dma_heap /dev/dma_heap/*"),
            ("dri-nodes", "ls -ldZ /dev/dri /dev/dri/*"),
            ("device-node-targets", "for p in /dev/mali0 /dev/dma_heap /dev/dma_heap/* "
             "/dev/dri /dev/dri/*; do if [ -e \"$p\" ] || [ -L \"$p\" ]; then "
             "printf '\\n%s\\n' \"$p\"; readlink -f \"$p\"; fi; done"),
            ("mali-sysfs-target", "readlink -f /sys/class/misc/mali0/device"),
            ("vulkan-system", "cmd gpu vkjson"), ("gpu-service", "dumpsys gpu"),
            ("surfaceflinger", "dumpsys SurfaceFlinger"),
            ("vulkaninfo-location", "command -v vulkaninfo"),
        ):
            self.query(name, command)
        props = text(self.results["getprop"])
        (self.output / "getprop-gpu.txt").write_text(
            "\n".join(line for line in props.splitlines() if PROP_WORDS.search(line)) + "\n",
            encoding="utf-8")
        prop_values = dict(re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", props, re.M))
        for name, keys in (
            ("android-version", ("ro.build.version.release", "ro.build.version.sdk")),
            ("soc-hardware", ("ro.soc.model", "ro.soc.manufacturer", "ro.hardware", "ro.board.platform")),
        ):
            (self.output / (name + ".txt")).write_text(
                "source=getprop.stdout.txt\n" + "\n".join(
                    key + "=" + prop_values.get(key, "não coletado") for key in keys) + "\n",
                encoding="utf-8")
        if status(self.results["vulkaninfo-location"]) == "observado" and text(self.results["vulkaninfo-location"]).strip():
            self.query("vulkaninfo-summary", "vulkaninfo --summary")
        else:
            self.notes.append("vulkaninfo não disponível; nenhuma ferramenta foi instalada.")

        for name, path in (("proc-version", "/proc/version"), ("proc-cpuinfo", "/proc/cpuinfo"),
                           ("proc-meminfo", "/proc/meminfo"), ("proc-modules", "/proc/modules"),
                           ("proc-mounts", "/proc/mounts")):
            self.read_file(name, path)

        self.discover_info()
        for name, command in (("dmesg", "dmesg"), ("logcat", "logcat -d -b all -t 4000 -v threadtime")):
            result = self.query(name, command)
            (self.output / (name + "-gpu.txt")).write_bytes(filtered_logs(result["stdout"]))

        # Inventory only: no reading of firmware blobs or proprietary libraries.
        self.query("libraries", "ls -ldZ /vendor/lib64/hw/vulkan* /vendor/lib/hw/vulkan* "
                   "/vendor/lib64/*mali* /vendor/lib64/*Mali* /vendor/lib64/egl/*mali* "
                   "/vendor/lib64/egl/*Mali* /vendor/lib/*mali* /vendor/lib/*Mali* "
                   "/vendor/lib/egl/*mali* /vendor/lib/egl/*Mali* "
                   "/system/lib64/libvulkan* /system/lib/libvulkan*")
        self.query("library-targets", "for p in /vendor/lib64/hw/vulkan* /vendor/lib/hw/vulkan* "
                   "/vendor/lib64/*mali* /vendor/lib64/*Mali* /vendor/lib64/egl/*mali* "
                   "/vendor/lib64/egl/*Mali* /vendor/lib/*mali* /vendor/lib/*Mali* "
                   "/vendor/lib/egl/*mali* /vendor/lib/egl/*Mali* "
                   "/system/lib64/libvulkan* /system/lib/libvulkan*; "
                   "do if [ -e \"$p\" ] || [ -L \"$p\" ]; then "
                   "printf '\\n%s\\n' \"$p\"; readlink -f \"$p\"; fi; done")
        for name, root, pattern in (
            ("vendor-modules", "/vendor_dlkm/lib/modules", "*mali*"),
            ("vendor-legacy-modules", "/vendor/lib/modules", "*mali*"),
            ("system-modules", "/system_dlkm/lib/modules", "*mali*"),
            ("vendor-firmware", "/vendor/firmware", "*mali*"),
            ("vendor-etc-firmware", "/vendor/etc/firmware", "*mali*"),
        ):
            self.query(name, "ls -ldZ %s; find %s -maxdepth 3 "
                       "\\( -iname %s -o -iname '*gpu*' -o -iname '*csf*' -o -iname '*kbase*' \\) "
                       "-exec ls -ldZ {} \\; -exec readlink -f {} \\;"
                       % (shlex.quote(root), shlex.quote(root), shlex.quote(pattern)))
        self.summarize()

    def discover_info(self):
        roots = []
        for index, base in enumerate(("/sys/class/misc", "/sys/class/devfreq", "/sys/module",
                                      "/sys/bus/platform/devices", "/sys/devices/platform/soc", "/sys/kernel",
                                      "/proc", "/proc/driver", "/sys/kernel/debug", "/debug", "/debugfs")):
            result = self.query("discovery-%02d" % index, "ls -1 " + shlex.quote(base))
            for entry in text(result).splitlines():
                if GPU_WORDS.search(entry) and entry not in (".", "..") and "/" not in entry:
                    roots.append(base + "/" + entry)
        # Discover additional already-mounted debugfs paths; never mount one.
        for line in text(self.results["proc-mounts"]).splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[2] == "debugfs":
                mount = fields[1].replace("\\040", " ").replace("\\011", "\t").replace("\\134", "\\")
                if mount not in ("/sys/kernel/debug", "/debug", "/debugfs"):
                    result = self.query("debugfs-mount-%d" % len(roots), "ls -1 " + shlex.quote(mount))
                    roots.extend(mount + "/" + e for e in text(result).splitlines()
                                 if GPU_WORDS.search(e) and "/" not in e and e not in (".", ".."))
        target = text(self.results["mali-sysfs-target"]).strip()
        if status(self.results["mali-sysfs-target"]) == "observado" and target.startswith("/sys/"):
            roots.insert(0, target)
        roots = list(dict.fromkeys(roots))
        if len(roots) > 64:
            self.notes.append("Descoberta limitada às primeiras 64 raízes; inventários originais preservados.")
        queue = collections.deque((root, 0) for root in roots[:64])
        visited, files = set(), set()
        while queue and len(visited) < 128 and len(files) < 256:
            path, depth = queue.popleft()
            if path in visited:
                continue
            visited.add(path)
            index = len(visited)
            self.query("info-inventory-%03d" % index, "ls -laZ " + shlex.quote(path))
            listing = self.query("info-entries-%03d" % index, "ls -1 " + shlex.quote(path))
            names = set(text(listing).splitlines()) if listing["exit_code"] == 0 else set()
            # Record known inaccessible attributes even when a device directory cannot be listed.
            if path == target:
                names.update(("gpuinfo", "core_mask"))
            for name in sorted(names & INFO_NAMES):
                full = path + "/" + name
                if full not in files and len(files) < 256:
                    files.add(full)
                    self.read_file("info-value-%03d" % len(files), full)
            if depth < 3:
                queue.extend((path + "/" + name, depth + 1) for name in sorted(names & INFO_DIRS))
        if queue or len(files) >= 256:
            self.notes.append("Limite de descoberta atingido (128 diretórios / 256 atributos / profundidade 3).")

    def summarize(self):
        props = dict(re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", text(self.results["getprop"]), re.M))
        rows = []
        for label, key in (("Modelo", "ro.product.model"), ("Device", "ro.product.device"),
                           ("Android", "ro.build.version.release"), ("API", "ro.build.version.sdk"),
                           ("SoC informado", "ro.soc.model"), ("Fabricante SoC", "ro.soc.manufacturer"),
                           ("Hardware", "ro.hardware"), ("Plataforma", "ro.board.platform"),
                           ("Build fingerprint", "ro.build.fingerprint")):
            rows.append((label, props.get(key, "não coletado"), "getprop.stdout.txt"))
        for label, name in (("Kernel", "kernel"), ("Identidade da consulta", "identity"),
                            ("Contexto SELinux", "selinux-context"), ("SELinux", "selinux"),
                            ("Nó Mali (metadados; não é teste de abertura)", "mali-node")):
            result = self.results[name]
            rows.append((label, text(result).strip() if status(result) == "observado" else status(result),
                         name + ".stdout.txt"))
        vk_result = self.results["vulkan-system"]
        vk_error = None
        if status(vk_result) == "observado":
            try:
                vk = json.loads(text(vk_result))
                for i, device in enumerate(vk.get("devices", [])):
                    properties = device.get("properties", {})
                    driver = device.get("driverProperties", {})
                    core = device.get("VK_ARM_shader_core_builtins", {}).get("shaderCoreBuiltinsPropertiesARM", {})
                    values = [("Nome", properties.get("deviceName")), ("Driver", driver.get("driverInfo")),
                              ("Shader cores", core.get("shaderCoreCount")), ("Shader core mask", core.get("shaderCoreMask"))]
                    for key in ("deviceID", "vendorID", "apiVersion"):
                        value = properties.get(key)
                        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value == int(value):
                            number = int(value)
                            value = "%d.%d.%d" % ((number >> 22) & 127, (number >> 12) & 1023, number & 4095) if key == "apiVersion" else hex(number)
                        values.append((key, value))
                    rows.extend(("Vulkan proprietário [%d] %s" % (i, label), str(value), "vulkan-system.stdout.txt")
                                for label, value in values if value is not None)
            except (ValueError, TypeError, AttributeError, OverflowError) as exc:
                vk_error = "Vulkan JSON inválido/incompatível; saída original preservada: " + str(exc)
        else:
            vk_error = "Informações Vulkan do sistema: " + status(vk_result)

        def cell(value):
            return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ")

        lines = ["# Diagnóstico G925", "", "Coleta UTC: " + datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 "", "Consultas via ADB; arquivos gravados somente no computador. Nenhum probe PanVK executado.",
                 "", "## Observações", "", "| Campo | Valor | Estado da fonte | Fonte |", "|---|---|---|---|"]
        for label, value, source in rows:
            source_status = status(self.results[source[:-len(".stdout.txt")]])
            if value == "não coletado":
                source_status = "não coletado"
            lines.append("| %s | %s | %s | [%s](%s) |" %
                         (cell(label), cell(value), source_status, source, source))
        lines += ["", "Os dados Vulkan são do driver proprietário carregado pelo sistema. deviceID não confirma RAW_GPU_ID/revision do kbase; suas features/extensões não comprovam suporte PanVK.",
                  "", "## Consultas incompletas", ""]
        incomplete = [(name, result) for name, result in self.results.items() if status(result) != "observado"]
        lines += ["- [%s](%s.command.txt): %s; saída=%s%s." %
                  (name, name, status(result), result["exit_code"], "; truncado" if result["truncated"] else "")
                  for name, result in incomplete]
        if not incomplete:
            lines.append("Todas as consultas concluíram dentro dos limites; isso não valida o driver PanVK.")
        lines += ["", "## Não coletado / próximo diagnóstico", "",
                  "- RAW_GPU_ID, product ID, revision/status e variant: requer consulta kbase ou fonte vendor correspondente.",
                  "- UAPI negociada, structs/ABI vendor, interface global CSF, instruction features, grupos/streams, registradores e suspend buffers.",
                  "- Topologia e registros brutos de shader/tiler/MMU/memória, caches, coerência e memory groups.",
                  "- Abertura real O_RDONLY/O_RDWR sob UID/contexto de aplicativo; ls e permissões não comprovam autorização SELinux.",
                  "- Semântica funcional de memória/import/export, fences, modifiers e WSI do PanVK: somente testes posteriores podem comprovar.",
                  "", "## Hipóteses", "",
                  "v13 é um candidato da investigação de referência, não uma identificação confirmada por este coletor. Não foi criado profile nem inferida versão CSF/UAPI."]
        if vk_error:
            self.notes.append(vk_error)
        lines += ["", "## Limites", "", "- 64 KiB por atributo; 4 MiB combinados de stdout/stderr por comando.",
                  "- Atributo que atinge 64 KiB é marcado truncado por precaução; seu tamanho real pode ser exatamente o limite.",
                  "- Timeout remoto Toybox: %s; timeout no host sempre ativo." % ("disponível" if self.remote_timeout else "indisponível"),
                  "- Logs brutos limitados preservados; *-gpu.txt contém linhas relacionadas e contexto de duas linhas."]
        lines.extend("- " + note for note in self.notes)
        (self.output / "SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        with (self.output / "COMMANDS.tsv").open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream, delimiter="\t")
            writer.writerow(("query", "status", "exit_code", "seconds", "host_timeout", "truncated", "command"))
            for name, result in self.results.items():
                writer.writerow((name, status(result), result["exit_code"], "%.3f" % result["duration"],
                                 result["timed_out"], result["truncated"], shlex.join(result["argv"])))
        print("Relatório: " + str(self.output / "SUMMARY.md"))
        print("Consultas: %d; incompletas: %d. Consulte SUMMARY.md e COMMANDS.tsv." % (len(self.results), len(incomplete)))


def main():
    parser = argparse.ArgumentParser(prog="collect-g925-info.sh",
                                     description="Diagnóstico Android/Mali sem root; escreve somente no computador.")
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"), help="serial ADB (ou ANDROID_SERIAL)")
    parser.add_argument("--output", default="g925-device-report", type=Path, help="novo diretório de saída")
    parser.add_argument("--timeout", default=30.0, type=float, help="timeout por comando, segundos (padrão: 30)")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
        parser.error("--timeout deve estar entre 0 (exclusivo) e 60 segundos")
    adb = shutil.which(os.environ.get("ADB", "adb"))
    if not adb:
        parser.error("ADB não encontrado; instale Android platform-tools no computador")
    output = args.output.expanduser().absolute()
    if os.path.lexists(output):
        parser.error("diretório de saída já existe: " + str(output))
    discovery = run_process([adb, "devices", "-l"], args.timeout)
    if status(discovery) != "observado":
        parser.error("não foi possível listar aparelhos: " + text(discovery, "stderr").strip())
    devices = {}
    for line in text(discovery).splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] != "List":
            devices[parts[0]] = parts[1]
    serial = args.serial
    if serial:
        if devices.get(serial) != "device":
            parser.error("aparelho selecionado ausente/offline/não autorizado: " + serial)
    else:
        ready = [key for key, value in devices.items() if value == "device"]
        if len(ready) != 1:
            parser.error("é necessário um único aparelho autorizado ou --serial explícito")
        serial = ready[0]
    connection = run_process([adb, "-s", serial, "get-state"], args.timeout)
    if status(connection) != "observado" or text(connection).strip() != "device":
        parser.error("conexão ADB inválida: " + text(connection, "stderr").strip())
    output.mkdir(parents=True, exist_ok=False)
    collector = Collector(adb, serial, output, args.timeout)
    collector.save("adb-devices", discovery)
    collector.save("adb-state", connection)
    collector.collect()


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        print("Erro de dependência/processo ou gravação do relatório: " + str(exc), file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        print("Coleta interrompida; arquivos parciais preservados no computador.", file=sys.stderr)
        sys.exit(130)
PY
