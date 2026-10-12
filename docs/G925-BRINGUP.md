# Immortalis-G925: investigação e diagnóstico inicial

Investigação inicial: 2026-10-05; revisão desta entrega: 2026-10-06.
As seções 1–7 registram as **Fases 0 e 1**, nas revisões fixadas abaixo.
As seções 8–13 registram a continuação standalone/gamescope do objetivo completo.
O runtime e o compositor DroidDeck continuam sem alterações funcionais.

A base inicial é [zenithblue-oss/panvk-kbase-android][panvk], uma camada de patches
e builds sobre Mesa fixado, com backend para o `mali_kbase` proprietário. Não
precisamos escrever Vulkan do zero nem substituir bibliotecas Android do sistema.

## 1. Fontes e revisões

Os três repositórios foram clonados em diretório temporário para inspeção. O
checkout local do DroidDeck estava na mesma revisão do clone de referência.
Os links abaixo fixam commits; descrições de suporte são relativas a essas revisões.

| Projeto | Revisão analisada |
|---|---|
| Droid-Deck/DroidDeck | `da29919b5a92e66523d55570960607eef35d1201` |
| Droid-Deck/Drivers | `27bf2ac1b386ac3399a7a5604ead18f067f652c3` |
| zenithblue-oss/panvk-kbase-android | `de577411e8f27da9de50aec26a0d8cc43890745e` |
| Mesa, em `sources.lock` do PanVK | `5a07217f034b3e50d8c7c7794f97a2df1742613b` (`26.3.0-devel`) |

[sources.lock][p-lock] também fixa referências externas e a identificação da
série de patches. Uma revisão de código que compila não comprova funcionamento
no Galaxy Tab S11; resultados publicados de outras GPUs não são resultados G925.

A [issue DroidDeck #165][issue165], aberta em 2026-10-03, discute a ausência de
ICDs glibc para GPUs não-Adreno. Cita encaminhamento para um processo Bionic,
libhybris, libmali glibc e forks PanVK-on-kbase. Aqui seguimos o último caminho,
com duas builds da mesma base. A issue é contexto de integração, não evidência de
compatibilidade do tablet.

Arquitetura futura, condicionada aos testes standalone:

```text
Android → compositor DroidDeck → PanVK Bionic → mali_kbase → Immortalis-G925
Linux runtime → gamescope/Steam/Proton/DXVK → ICD PanVK glibc → /dev/mali0 → GPU
```

## 2. PanVK/kbase: pontos de entrada e contratos

### Profiles, gerações e patches

Profiles são arquivos `profiles/<nome>.json`, não diretórios. O script
[apply-patches.sh, linhas 13–39][p-apply] lê `panArch` e `frontend` e aplica
`common`, `android`, `kbase-common`, `app-loader`, `wsi`, depois `csf` e
`csf-v<arch>` ou `jm-v<arch>`. Para `g615-v11-csf`, acrescenta `jm-v9`: a receita
universal atualmente utiliza esse profile e a série extensa `csf-v11`, apesar de
compilar backends de outras gerações. Isso não é um seletor JSON de profiles em
runtime: a GPU é identificada pelos ioctls e pelo modelo/dispatch Mesa.

| Profile existente | Backend | Estado nas fontes inspecionadas |
|---|---|---|
| `g52-v7-jm` | v7 / JM | Planejado; não validado por este projeto |
| `g57-v9-jm` | v9 / JM | Experimental, resultados limitados em Lenovo TB336FU; PanProbe 1/17 |
| `g610-v10-csf` | v10 / CSF | Profile planejado; backend incluído no universal, sem validação publicada nessa GPU |
| `g615-v11-csf` | v11 / CSF | Principal referência testada: Poco X6 Pro; não equivale a conformidade completa |
| `g720-v12-csf` | v12 / CSF | Profile planejado; backend compilado, sem validação publicada nessa GPU |

Fontes: [profiles fixados][p-profiles], [CHANGELOG beta.16][p-changelog] e
[README, tabela de GPUs][p-readme]. O profile G57 ainda diz “not in universal
ICD”, enquanto a receita e o changelog já incluem `jm-v9`; registrar essa
inconsistência, sem promover G57 a suportada.
O profile G57 descreve o único caso PanProbe como SKIP; o número 1/17 isolado
não comprova execução bem-sucedida de uma feature.

O [Meson upstream fixado][m-meson] diferencia Valhall `[9,10,11]` de fifthgen
`[12,13,14]` e compila PanVK para `[6,7,10,11,12,13,14]`; o v9 vem do port do
projeto. A inicialização kbase permite v10–v14 no [patch 004, linhas 846–900][p-physical].
Build, admissão e funcionamento são três propriedades diferentes. G615/G715 são
referências v11; G720, v12; G725, v13. A [investigação de arquiteturas][p-architectures]
associa G925 a v13, mas classifica essa associação como evidência intermediária.
**v13 é candidato para este tablet, não um valor confirmado por kbase aqui.**
Não há profile G925 nas fontes analisadas.

`PAN_ARCH` é definido na compilação das bibliotecas por geração. O
[panvk_macros.h do Mesa fixado, linhas 45–123][m-dispatch] produz símbolos
`panvk_v10_*`, `panvk_v11_*`, `panvk_v12_*` e os demais; o dispatch em runtime
escolhe a geração derivada de `pan_arch(gpu_id)`. Features, propriedades e
entrypoints passam por esse dispatch ([patch 004, linhas 936–959][p-dispatch]).
Uma alteração em `csf-v11` pode conter código comum e código condicionado por
`PAN_ARCH`; aplicar essa família não significa validar todas as gerações.

As famílias e os cabeçalhos de proveniência estão em [patches/README.md][p-patches].
Pontos principais: patches 001–003 acrescentam o backend Meson/kmod; 004–006
conectam physical device, enumeração, dispositivo lógico e WSI; `csf/007` trata
submission; `android/008` e `013` tratam AHB/metadados gralloc; `app-loader/001`
expõe símbolos ICD; `wsi/016` trata a superfície Android. `csf-v11/018`–`107`
acrescentam contratos e correções, inclusive features e sincronização; `jm-v9`
é um port real, não apenas uma opção de build. O patch `017` desativa
`VK_KHR_depth_clamp_zero_one`, `VK_KHR_pipeline_binary` e `VK_KHR_robustness2`.
Os aliases EXT não são desligados por esse patch na revisão analisada; não
confundir esse filtro com validação completa. Não remover gates para agradar apps.

### Identificação, abertura e versões

[instance-enumerate, linhas 43–106][p-enumerate] procura `/dev/maliN`, além do
caminho DRM existente. O [physical device][p-physical] abre o nó com
`O_RDWR | O_CLOEXEC`. Cada `VkDevice` abre um **novo fd**, em vez de duplicar o
fd físico: duplicação compartilharia contexto e a negociação kbase não pode
ser repetida nesse contexto ([device-queue, linhas 183–224][p-device]).

O [backend kbase, linhas 1127–1330][p-kmod-init] negocia primeiro
`VERSION_CHECK_CSF`, depois JM; executa `SET_FLAGS`, mapeia tracking e consulta
`GET_GPUPROPS` em duas chamadas, tamanho e conteúdo. O parser
[linhas 182–395][p-kmod-props] usa `RAW_GPU_ID` ou os campos separados de
product/revision/status, além de variant, shader mask e registros de features.
O código contém fallbacks de hardware/coerência: precisam de investigação no
alvo e não devem ser copiados como fatos G925.

Separar sempre:

- **DDK/vendor release**: exemplo observado no Vulkan proprietário, `r49p1`.
- **kbase UAPI**: major/minor negociados por ioctl; ainda desconhecidos no tablet.
- **CSF firmware/global interface**: versão e capabilities de `CS_GET_GLB_IFACE`.
- **Mesa PAN_ARCH/modelo/variant**: seleção derivada de dados de hardware.

[kbase_query_csif_info, linhas 402–476][p-kmod-csif] consulta grupos/streams,
features e suspend size e traduz para o contrato compartilhado com CSF. O backend
contém fallbacks de contagem de registradores e layouts de criação de grupo por
versão ([linhas 510–577][p-kmod-groups]). São decisões da implementação atual,
não evidência de versão CSF/UAPI G925. Os headers estão em
`patches/kbase-common/files/src/panfrost/lib/kmod/`: `kbase_uapi.h`,
`kbase_csf_uapi.h` e headers `mali_base*`. Comparar com o código vendor do build
exato antes de introduzir uma nova ABI.

### Memória e interoperabilidade

[Inicialização][p-kmod-init] estabelece tracking, zonas JIT/EXEC_VA e contexto.
[Alocação e importação, linhas 1439–1754][p-kmod-memory] usam SAME_VA/cookies,
`MEM_ALLOC`/`MEM_ALLOC_EX`, mmap e `MEM_IMPORT` para DMA-BUF. Há diferenças entre
munmap de SAME_VA e liberação explícita de regiões EXEC_VA. Cache maintenance
fica em [flush_bo_map_syncs, linhas 1852–1885][p-kmod-cache].

`/dev/dma_heap/system` é o heap padrão, substituível por
`PANVK_KBASE_DMA_HEAP`; disponibilidade do heap é usada como condição de alguns
caminhos. Não comprova que import/export e sincronização funcionem no tablet.
BOs com DMA-BUF têm exportação por duplicação do fd; BOs exclusivamente kbase
sem esse fd não ganham exportação automaticamente. Placed maps dependem de um
DMA-BUF real e não são simulados por cópia anônima.

O comentário do caminho legado `bo_import(handle)` diz “not yet implemented”;
essa função realmente retorna `ENOSYS`. Porém, **`bo_import_fd` está implementado**
e chama `kbase_kmod_import_dmabuf`. Não concluir que toda importação esteja
ausente por causa do comentário antigo. Os callbacks são registrados em
[kbase_kmod_ops, linhas 2011–2040][p-kmod-ops].

AHB/gralloc exige metadados reais: não presumir que `native_handle_t->data[0]`
seja o fd correto, nem transformar um modifier desconhecido em LINEAR. Essa é
uma regra explícita em [ARCHITECTURE.md][p-architecture].

### Submission, sincronização e WSI

[CSF queue backend][p-csf-submit] organiza subfilas, contadores de conclusão e
tiler heaps. O [kmod][p-kmod-groups] cria grupos, registra/binda ring buffers,
mapeia páginas de user I/O e aciona `CS_QUEUE_KICK`/doorbells. Faults vêm das
notificações kbase; a conclusão não utiliza timestamps KGSL.

O tipo `vk_sync` específico vive no [patch physical-device, linhas 787–838][p-sync].
Tem estado e waits próprios; timelines são conectadas pelo runtime Vulkan.
Não há DRM syncobj nativo nesse fd, apesar do nome de um campo interno.
Submission originalmente esperava semáforos no CPU; patches posteriores
introduzem waits GPU para filas compatíveis e ajustam memória CSF event,
backpressure e renovação de heaps. Para G925, isso ainda requer teste.

[csf-v11/075][p-syncfd] implementa exportação de `sync_file` por fila KCPU,
esperando conclusão GPU antes do fence sinalizado. Importação e waits precisam
manter o contrato do handle; não confundir presença do código com validação G925.

[WSI, linhas 269–318][p-wsi] usa apresentação por cópia por padrão no caminho
kbase. DMA-BUF depende de opções como `PANVK_KBASE_DRI3`/`WSI_X11_TERMUX`, heap
e transporte compatível; o protocolo raw-FD de Termux:X11 não é comprovação de
Wayland/gamescope. Modifier support também é condicionado. Evitar habilitar
opções para esconder falhas de importação.

### Builds, pacotes e testes existentes

Receita Bionic de referência, **somente para G615**, não uma instrução de suporte G925:

```sh
./scripts/fetch-mesa.sh
./scripts/apply-patches.sh --profile g615-v11-csf
./scripts/build-android.sh --profile g615-v11-csf --api 35 --ndk "$ANDROID_NDK_ROOT"
./scripts/validate-binary.sh --abi android dist/android-g615-v11-csf/libvulkan_panfrost.so
```

[build-android.sh, linhas 6–54][p-build-android] assume toolchain NDK
`linux-x86_64`, ferramentas nativas de codegen e dependências Bionic separadas.
Usa `platforms=android,x11`, `vulkan-drivers=panfrost`, `panfrost-kmds=kbase`.
O artefato é `libvulkan_panfrost.so`; os símbolos ICD genéricos coexistem com
Android WSI. Não tentar essa receita Linux diretamente no macOS sem adaptar o
ambiente de build em uma fase posterior.

[build-glibc.sh, linhas 40–95][p-build-glibc] gera a biblioteca e
`panfrost_icd.aarch64.json` nativamente em Linux ARM64, com WSI X11/Wayland. Em
outros hosts, a alternativa existente faz push e usa wrapper chroot com
`--user root`; esse caminho modifica arquivos no dispositivo e **não faz parte
da coleta inicial**. Ainda será necessário validar build/execução equivalentes
ao PRoot do DroidDeck sem root.

[package-android-adpkg.sh][p-package-android] e [package-glibc.sh][p-package-glibc]
contêm nome/defaults G615 para gpuId, panArch e UAPI; o glibc também pode gerar
manifest fallback com API 1.4.0. Nunca reutilizar esses defaults como metadata
G925. Esta entrega não altera o empacotamento.

| Teste existente | O que procura comprovar |
|---|---|
| `tests/kbase-probe/probe.c` | Existência, open O_RDONLY/O_RDWR, sysfs e kernel; rodar separadamente sob shell e app UID |
| `tests/kbase-probe/handshake.c` | Negociação, SET_FLAGS e tracking; não captura sozinho o blob completo de props/interface |
| `tests/vulkan-smoke` | Carregamento ICD, instance, enumeração, device e buffers |
| `tests/compute` | Dispatch mínimo e leitura exata de resultado |
| `tests/offscreen` | Desenho e readback; não aceitar apenas clear como prova de rendering |
| `tests/ahb` | AHB real, propriedades/import/bind e verificação |
| `tests/android-surface` | Swapchain real, frames limitados, resize/recreate e encerramento |
| `tests/sync` / `android-loader-app` | Fence/semaphore/timeline, múltiplos submits e UID comum de app |

Fonte: [tests/README.md][p-tests]. Nenhum desses testes foi executado nesta
entrega. A documentação `PORTABILITY.md` diz “never X11” para Bionic, enquanto
o script atual explicitamente compila Android+X11: usar o código como referência
e não repetir a restrição desatualizada. A validação G615 publicada inclui falhas
CTS remanescentes; nem G615 deve ser apresentada como totalmente conforme.

## 3. DroidDeck: gerenciamento de drivers e caminho dos frames

### Android/display

[SessionActivity, linhas 927–990][d-activity] resolve `TurnipDriver.install()` e
passa pasta, libraryName e nativeLibraryDir ao `CompositorHost`/JNI.
[CompositorHost, linhas 29–47][d-host] repassa esses parâmetros para a chamada nativa.
[TurnipDriver, linhas 248–365][d-turnip] valida ELF AArch64 e rejeita glibc na
lista Bionic; seleciona imports, overrides ou bundled Turnip pela GPU.
[JNI, linhas 253–260][d-jni] configura o driver em `vk_present_set_driver`.
[vk_loader_open, linhas 17–44][d-loader] chama `adrenotools_open_libvulkan` para
driver custom e cai em `dlopen("libvulkan.so")` se não conseguir. Esse fallback
nunca poderá contar como sucesso de um teste PanVK: registrar a biblioteca e
driver realmente carregados é parte da validação futura.

### Linux/runtime e bundles

[LinuxVulkanDriverManager, linhas 181–225][d-linux-manager] exige ELF AArch64,
indício de glibc `libc.so.6`, nome `libvulkan_freedreno.so` e gera `icd.json` com
library_path absoluto e API literal `1.1.274`. É validação heurística existente,
não um contrato genérico de drivers PanVK.

[SessionService, linhas 552–560][d-service] configura o ICD do runtime e passa
`BL_VK_DRIVER` para imports. [droiddeck-session, linhas 59–84][d-session] verifica
manifest/library legíveis, resolve escapes/caminhos relativos e exporta
`VK_DRIVER_FILES` e `VK_ICD_FILENAMES`. gamescope, Steam e programas filhos
herdam essa seleção; wlroots/labwc também utiliza o ambiente da sessão.
[droiddeck-desktop, linhas 24–42][d-desktop] seleciona renderer e wlroots patchado.

[DriverBundle, linhas 44–125 e 181–193][d-bundle] instala ambas as metades,
reverte a primeira se a segunda falhar, registra o par e mantém seleção/remoção
conjuntas. O manifest parece genérico, mas a adoção Linux procura explicitamente
`libvulkan_freedreno*.so`. `DriverPairs` e preferências já oferecem pareamento;
não é suficiente renomear PanVK para freedreno e declarar compatibilidade.

### Dependências Adreno/KGSL

| Área | Acoplamento atual / fonte |
|---|---|
| Detecção | [GpuInfo.detect, linhas 55–77][d-gpuinfo]: sysfs KGSL ou `vulkan.adreno.so`; não-Adreno marcado unsupported |
| Nós e ICD padrão | [LinuxRuntime, linhas 101–109 e 286–325][d-runtime]: preferência freedreno, KGSL apresentado como render node e entradas sysfs correspondentes |
| Apps com bwrap | [BwrapSpawner, linhas 228–250][d-bwrap]: biblioteca freedreno, nó KGSL e ICD próprio |
| PRIME/GEM | [preload/drm.c][d-drm-preload]: handles emulados somente para fd identificado como KGSL |
| Chip ID / polls | [kgslid.c][d-id-preload] e [kgslpoll.c][d-poll-preload]: interceptação dos ioctls Qualcomm específicos |
| Estatísticas | [GpuStatsComponent, linhas 50–68][d-stats] e [GpuMemComponent, linhas 84–111][d-memory]: caminhos KGSL e proxies para HUD |
| Clocks/turbo | [GpuClockPin, linhas 20–40][d-clocks], JNI/adrenotools: mecanismo KGSL específico |

Um nó kbase não se torna DRM porque foi exposto sob `/dev/dri`. A semântica
ioctl/PRIME/fences precisa ser investigada isoladamente antes de generalizar
esses mecanismos. Não copiar emulação KGSL para Mali nesta fase.

### Frames, DMA-BUF e superfície Android

No caminho normal, `zwp_linux_dmabuf_v1` transporta fd, format, modifier,
offsets e strides. [compositor.take_dmabuf, linhas 761–780][d-compositor] importa
o buffer com [vkp_image_from_dmabuf, a partir da linha 934][d-present], usando
memória externa e metadata de layout; Vulkan compõe para a superfície Android.
LINEAR/UBWC e a negociação de feedback têm decisões Qualcomm específicas.

[ahb_swapchain, linhas 275–339][d-ahb] recebe AHardwareBuffer real por Unix
socket pelo protocolo `banner_ahb_v1`, valida dimensões e guarda referência.
O caminho SurfaceControl apresenta AHB com acquire fence. [linhas 132–151 e
202–220][d-ahb-fences] exportam/importam sync_file no DMA-BUF e, se o ioctl falhar,
esperam fences no CPU. [sc_layer][d-layer] usa `ASurfaceTransaction_setBuffer`.
Essa integração exige que o produtor implemente o protocolo e os fences reais;
AHB não é apenas um fd PRIME. O patch [wlroots Vulkan allocator][d-wlroots]
aloca/exporta DMA-BUF por Vulkan quando o nó não é DRM/GBM, mas não valida Mali.

Após standalone, pontos de reutilização para um futuro `GpuBackend`: separação
display/runtime, manifest de bundle, registry/pareamento, passagem de driver
ao host/JNI e ambiente da sessão. Encapsular identificação, nós, artefatos,
ICD/environment, capabilities comprovadas, quirks e gates. Nenhuma interface
`GpuBackend`, condição `if (mali)` ou alteração de comportamento Adreno foi criada.

## 4. Droid-Deck/Drivers

[build_android.sh][r-android] usa NDK/API 34, platform SDK 36,
`vulkan-drivers=freedreno` e `freedreno-kmds=kgsl`.
[build_linux.sh][r-linux] faz cross build ARM64 glibc com sysroot e
`freedreno-kmds=msm,kgsl`, WSI Wayland/X11. Ambos recebem a mesma revisão Mesa.
[patches/series.json][r-series] ordena patches gralloc/UBWC, IDs/quirks Adreno,
PWR_MAX, WSI KGSL e sincronização; não são patches PanVK.

[package_bundle.py, linhas 20–47 e 133–181][r-package] valida ABI/libc,
marcadores de plataforma, PWR_MAX e revisão Mesa comum; publica manifest,
metadados, hashes, licenças e código-fonte correspondente. A receita resolve Mesa main
por release ([README][r-readme]), diferentemente do pin explícito da base PanVK.
O futuro pipeline G925 deverá manter pin e gates próprios, preservando Turnip;
nenhuma mudança de build/CI é feita agora.

## 5. Evidências do Galaxy Tab S11

As consultas de 2026-10-05 foram feitas por ADB sob UID 2000/shell, sem root.
Os valores abaixo são **observados**, com suas fontes, não defaults de profile.

| Campo | Resultado observado | Fonte |
|---|---|---|
| Modelo/device | `SM-X730` / `gts11wifi` | getprop |
| Android / API | 16 / 36 | getprop |
| Fabricante SoC / modelo / plataforma | `Mediatek` / `MT6991` / `mt6991`; hardware `mt6991` | getprop; o nome comercial Dimensity 9400+ é contexto fornecido pelo usuário |
| Kernel | `6.6.102-android15-8-abogkiX730XXS9BZI1-4k`, aarch64 | uname |
| SELinux / contexto | Enforcing / `u:r:shell:s0` | getenforce; id -Z |
| `/dev/mali0` | `crw-rw-rw-`, system:graphics, `gpu_device`, major/minor 10:92 | ls -ldZ; não é teste de open |
| Sysfs Mali | `/sys/devices/platform/soc/48000000.mali` | readlink -f |
| Módulo encontrado | `mali_kbase_mt6991_r49`, além de módulos MGM/protected allocation | inventário /sys/module; nome não confirma UAPI |
| DRM | `/dev/dri/card0`, system:system, modo 0660 | inventário; nenhum render node observado |
| dma-heaps | system, system-uncached, mtk_mm e outros | inventário /dev/dma_heap; não é teste de allocation/import |
| Nome Vulkan | `Mali-G925-Immortalis MC12` | cmd gpu vkjson, driver proprietário |
| Identidade Vulkan | deviceID `0xd8300010`, vendorID `0x13b5` | cmd gpu vkjson; não confirmado como RAW_GPU_ID |
| Vulkan proprietário | 1.3.278 | apiVersion de cmd gpu vkjson |
| Vendor driverInfo | `v1.r49p1-03bet0.f8a98b506b89b21c80a508d70abfcb3f` | cmd gpu vkjson |
| Shader cores/mask | 12 / `0x0000000000ee0077` | VK_ARM_shader_core_builtins proprietário; confirmar por kbase |

**Não acessível ao shell:** `gpuinfo`, `core_mask`, `version` e `srcversion` do
módulo; `dmesg` negou `klogctl`. Modo de arquivo legível não elimina a política
SELinux. **Não coletado:** RAW_GPU_ID, revision e versões negociadas por ioctl.
Nenhuma dessas recusas comprova necessidade de root ou impede tentar um probe
sem root em uma fase posterior. Vulkan do sistema não é PanVK standalone.

### Informações ainda necessárias

| Informação | Fonte/ação posterior necessária | Por que bloqueia o próximo gate |
|---|---|---|
| RAW_GPU_ID, product ID, revision/status, variant | GET_GPUPROPS com headers comprovados ou código vendor correspondente | Seleção correta do modelo e arquitetura; não usar deviceID Vulkan como substituto |
| kbase UAPI e structs/ABI vendor | VERSION_CHECK e comparação do código kernel/vendor do build exato | Layouts, compatibilidade e flags de ioctls |
| CSF global version/firmware, grupos/streams, instruções, registradores, suspend buffers | CS_GET_GLB_IFACE e registros/vendor acessíveis | Criação de filas e geração de command streams |
| Topologia bruta, tiler/L2, MEM/MMU/TEXTURE/features, coherency | GPUPROPS, código vendor e documentação primária | Memória, cache maintenance e limites reais |
| Memory groups, heaps, flags/restrições | módulos MGM/vendor e testes isolados posteriores | Allocation, import/export e regiões protegidas |
| Open sob app UID/SELinux | probe NDK/app isolado, O_RDONLY e O_RDWR com errno/contexto | Shell, system service e app têm permissões diferentes |
| Correspondência G925 ao Mesa fixado | RAW_GPU_ID + variant + tabela/modelo/dispatch do pin | Confirmar v13 candidato e separar diferenças de G615/G715/G720/G725 |
| Memória externa, modifiers, sync_file, WSI PanVK | workloads de compute/offscreen, depois interop/WSI | Somente execução comprova capabilities; vendor vkjson não as transfere |

Não construir profile até existir evidência suficiente. Se sysfs/proc continuar
restrito, a próxima investigação é consulta nativa isolada e comparação com
fontes vendor, não `su`, chmod ou SELinux permissive automáticos.

## 6. Coletor e reprodução

`tools/collect-g925-info.sh` é entrada Bash para Python **3.8 ou mais recente**
embutido; depende apenas da biblioteca padrão e de ADB no computador. `ADB`
pode indicar o executável para testes/instalações alternativas.

No computador, com depuração USB já autorizada no tablet:

```sh
adb devices -l
bash tools/collect-g925-info.sh --serial SERIAL_ADB --output g925-device-report
tar -czf g925-device-report.tar.gz g925-device-report
```

`ANDROID_SERIAL` substitui `--serial`; sem ambos, precisa existir exatamente um
aparelho autorizado. Não reutiliza diretório de saída existente. Para manter o
pacote fora do checkout, use um diretório novo fora dele em `--output` e ajuste
o `tar -C` correspondente. Nenhum comando precisa ser executado manualmente
no shell do tablet.

Cada consulta produz `<nome>.stdout.txt`, `.stderr.txt` e `.command.txt`, com
comando efetivo, duração, código de saída, timeout e truncamento. `COMMANDS.tsv`
indexa consultas; `SUMMARY.md` separa observações, consultas incompletas,
pendências e hipóteses. getprop completo, logs brutos limitados e Vulkan JSON
proprietário são preservados; `*-gpu.txt` contém filtros com duas linhas de
contexto. `android-version.txt` e `soc-hardware.txt` são extraídos do getprop,
com indicação da fonte. Inventários registram labels e destinos de symlinks;
módulos e firmware permanecem inventários, sem leitura dos blobs.
Informação sensível presente nos logs originais não é redigida pelo
coletor: o pacote permanece local, sem upload automático. logcat consulta as
últimas 4.000 linhas para preservar contexto recente antes de aplicar o cap.

Limites: 64 KiB por atributo, 4 MiB combinados stdout/stderr por comando (64 KiB
reservados para stderr para não perder erros após stdout volumoso), até
64 raízes/128 diretórios/256 atributos e profundidade 3. Só atributos
informativos explicitamente permitidos são lidos; demais entradas ficam no
inventário. Descobre mounts debugfs existentes, mas não monta nenhum. Não lê
mais de 64 KiB de cada atributo no tablet; atingir esse limite sinaliza possível
truncamento, mesmo quando o arquivo tem exatamente esse tamanho. Não lê
blobs de firmware/bibliotecas, não instala vulkaninfo e não executa probes
nativos ou ioctls novos. `cmd gpu vkjson` consulta o driver existente do sistema.

Timeout padrão de 30 s por comando (ajustável com `--timeout`, máximo 60),
Toybox remoto quando disponível, mais deadline de processo no host. Falhas de
permissão, ausência de comando/arquivo, timeout e desconexão durante a coleta
não abortam as demais consultas. Saída 0 significa que o relatório foi produzido,
**não** que todas as consultas passaram. Saída 2 indica argumento/dependência,
seleção/conexão inicial ou gravação inválidos; 130 indica interrupção manual.

## 7. Verificação e próximo milestone

Não há driver para compilar nesta entrega. Validação local:

```sh
bash -n tools/collect-g925-info.sh
bash tools/collect-g925-info.sh --help
```

Os testes de ADB simulado ficam em diretório temporário, sem novos arquivos
versionados. Cobrem permissões negadas, comando ausente, JSON inválido,
desconexão, timeouts remoto/host, caps de arquivo/saída, seleção múltipla,
aparelho não autorizado, serial explícito/ambiente, argumentos inválidos e
recusa de diretório existente. A coleta real usa somente consultas e grava o
pacote fora do repositório.

Resultados da revisão executada em 2026-10-06:

- Sintaxe Bash e compilação em memória do Python embutido: PASS.
- 23 cenários de validação: PASS, incluindo ADB simulado, preservação de stderr
  após stdout volumoso, falha de conexão inicial e serial ausente.
- Dependências ausentes (ADB/Python) e diretório de saída não gravável: PASS,
  retorno 2 sem tentar contornar a falha.
- Captura real preservada do SM-X730, de 2026-10-06 às 10:47:28 UTC:
  **187 consultas**, 156 observadas, 26 não acessíveis e 5 não coletadas;
  nenhum timeout ou truncamento. Relatório gerado com saída 0.
- GPU identificada pelo Vulkan proprietário como G925 MC12; sysfs restrito e
  dmesg negado preservados no relatório. `vulkaninfo` não estava instalado.
- Não coletadas: ausência de vulkaninfo, `/debug`, `/debugfs`, alguns glob patterns
  de bibliotecas e `/vendor/etc/firmware`; os resultados parciais são preservados.
- Revisão final restrita aos dois arquivos deste milestone. Sem builds PanVK,
  root, substituição de bibliotecas, instalação de APK ou alteração do tablet.

Na revalidação desta entrega, o coletor passou novamente os 23 cenários e seu
conteúdo foi comparado byte a byte com a versão usada na captura preservada
(SHA256 `aff81ea23a3eee889618e4a31c0e2f16f5a1001e4eab5c4da4f0d9b9801e2d0c`).
O ADB não encontrou aparelho conectado para uma nova captura nessa sessão;
os resultados reais acima pertencem à captura preservada. Os 187 registros
foram conferidos quanto à presença de stdout, stderr e metadados individuais.

Possíveis limitações: o shell pode observar menos que um app ou serviço system;
scans/saídas limitados podem omitir informação, com truncamento registrado;
sysfs informativo varia entre vendors. Não há regressão funcional esperada para
Adreno, porque seus arquivos e execução não foram alterados.

Próximo passo: revisar o pacote e obter dados kbase/CSF reais com probe isolado
e headers vendor comprovados. Só depois propor o profile e patches G925
separados de mudanças genéricas. A integração DroidDeck fica bloqueada até
standalone abrir o nó, criar VkInstance, enumerar a GPU correta, criar VkDevice
e completar compute/offscreen/sync estáveis. Não executar glibc/gamescope/DXVK
nem criar CI ou VKD3D-GAPS nesta fase.


## 8. Continuidade autorizada: primeiros testes standalone

O trabalho de driver está no checkout separado
`/Users/vinibecker/workspace/panvk-kbase-android`, branch `codex/g925-bringup`.
Mesa permanece fixado em `5a07217f034b3e50d8c7c7794f97a2df1742613b`.
As pendências da seção 5 descrevem a coleta inicial; os probes posteriores
preencheram parte delas, sem acrescentar ioctls ao coletor de diagnóstico.

O probe nativo e sua versão JNI confirmaram, sem root: RAW_GPU_ID
`0xd8300015`, variant 4, UAPI CSF 1.30, interface global CSF `0x030a0000`,
8 grupos/64 streams e shader mask `0xee0077`. Os blobs shell/app são idênticos.
As propriedades de revision major/minor são 0/1; VERSION_STATUS é 0, enquanto
o nibble de status do ID bruto é 5. Essa diferença permanece registrada.
O ID Vulkan proprietário `0xd8300010` continua separado do ID bruto.

A tabela do Mesa fixado seleciona arch=13 e o modelo compartilhado G725
para esses valores. O profile `profiles/g925-v13-csf-uapi1.30.json` registra
os dados medidos e as diferenças para as referências. Um patch separado em
`patches/csf-v13/001-g925-measured-device-name.patch` corrige somente o nome
para o ID/variant exatos medidos; não altera o modelo nem habilita capabilities.
A série utilizada tem 18 patches de base e esse patch específico G925.

| Gate | Bionic, shell | Bionic, app comum | glibc, loader direto no shell |
|---|---|---|---|
| ICD explícito / VkInstance | PASS | PASS | PASS |
| G925 MC12, ID `0xd8300015`, driver PanVK | PASS | PASS | PASS |
| VkDevice / buffer / compute exato 10/10 | PASS | PASS | PASS |
| Image allocation / triângulo offscreen 64×64 | PASS | PASS | PASS |
| Fences / semáforo binário / 20 submits | PASS | PASS | PASS |
| Timeline / synchronization2 | PASS, teste focado | Não coletado | Não coletado |

No teste Bionic, o app executou via JNI sob UID 10413 e contexto
`u:r:untrusted_app:s0:c157,c257,c512,c768`, em dois processos novos, PIDs
25706 e 25835. `run-as` apenas recuperou os arquivos; o resultado anterior
foi removido antes da segunda execução. APK/dados e os diretórios temporários
dos testes shell foram removidos. Nenhuma biblioteca do sistema foi substituída.

O readback gráfico distinguiu vermelho da geometria e azul do clear; não é
apenas teste de clear. Não houve crash ou DeviceLost observado nesses workloads.
`dmesg` continua inacessível. O dump de features/extensões é agora do PanVK:
API **reportada** 1.4.363 não comprova conformidade. Geometry/tessellation,
vertexPipelineStoresAndAtomics e BC são reportados como ausentes nessa base;
não foram falsificados para aplicações.

Evidências, hashes e comandos estão em `validation/g925-bringup/bionic/` e
`validation/g925-bringup/glibc-direct/` no checkout do driver. A biblioteca
Bionic qualificada tem SHA256
`f6ef1401f1df2032988d1582d5b8dfb29c1d2d637b996e11535bf52df518216f`.

Naquele milestone, o teste glibc direto provou execução dessa ABI e acesso ao
mesmo `/dev/mali0` sob shell. A seleção pelo Vulkan loader/JSON, PRoot, UID de app
no runtime Linux, WSI e interoperabilidade ainda estavam pendentes,
antes de gamescope, integração DroidDeck e DXVK. CI/pacotes reproduzíveis e
`VKD3D-GAPS.md` continuam no objetivo completo, sem marcar a integração concluída.

## 9. Vulkan loader, PRoot e investigação Wayland (2026-10-06)

O ICD glibc foi selecionado pelo Vulkan loader público Ubuntu ARM64
1.3.275.0-1build1, com `VK_DRIVER_FILES` e `VK_ICD_FILENAMES` explícitos.
Um JSON inexistente retornou `VK_ERROR_INCOMPATIBLE_DRIVER`; não houve fallback
bem-sucedido. Enumeration, device, compute, offscreen, sync e `vulkaninfo
--summary` passaram no shell e sob o PRoot existente do DroidDeck, inclusive
em duas execuções de app `untrusted_app`. Evidência:
`validation/g925-bringup/glibc-loader/validation.json` no checkout PanVK.
O rootfs é uma closure Ubuntu temporária, com os mesmos binds essenciais e
PRoot do projeto; a sessão Arch/Steam/FEX completa ainda precisa ser validada.

O teste Linux WSI usa `vkcube-wayland` 1.3.275, Weston 13 headless com Pixman,
PRoot e diretório privado de um app comum. O servidor no contexto shell negou
`bind()` do socket em `/data/local/tmp`; isso não pediu root. Em contexto de app
o socket funciona. A apresentação usa cópia/SHM: não comprova DMA-BUF,
modifiers, explicit sync ou gamescope.

A biblioteca inicial falhou com CSF `0x49`, definido como
`CS_INVALID_INSTRUCTION` nos headers ARM incluídos pela base. O decode mostrou
um stream de comandos sobrescrito. Reduzir para um frame ainda gerou fatal e
timeout, mesmo com exit code zero: o verificador passou a rejeitar esses logs.
Desativar mappings em cache não corrigiu a falha; `PANVK_DEBUG=no_crc` permitiu
duas execuções de 300 frames apenas como controle diagnóstico.

A causa identificada é a chamada direta a `os_munmap` na inicialização de CRC
em `panvk_image_plane_bind_mem`. No kbase/SAME_VA, isso também libera o mapping
GPU, deixando a imagem referenciar VA que pode ser reutilizada por um BO de
comandos. A própria base já tinha a correção em `csf-v11/038`. Movemos seu hunk
inalterado para `patches/kbase-common/018-crc-init-kmod-munmap.patch`, usando
`pan_kmod_bo_munmap`. O patch G925 de identificação permanece separado. A série
G615 completa aplicou sem conflito na revisão Mesa fixada; isso valida aplicação,
sem alegar teste em hardware G615. Não houve mudança de capabilities.

As duas ABIs recompilaram. O driver glibc corrigido apresentou 300 frames em
cada uma de duas execuções frias, sem `PANVK_DEBUG` e sem fatal/timeout nos logs.
A regressão Bionic sob app comum passou enumeration, device, compute, 20 renders
com readback vermelho/azul e 20 submissions de sincronização em dois processos.
Os artefatos candidatos ficam em `build/g925-artifacts/crc-fixed/` no driver.

Próximos gates: Android WSI/AHB, testes isolados de DMA-BUF/modifiers/fences,
gamescope na sessão completa e somente depois abstração `GpuBackend` e DXVK.
O runtime e o compositor DroidDeck continuam sem alterações funcionais. Os APKs
e dados usados neste milestone foram removidos; `dmesg` permaneceu negado.
A implementação final continua pendente.

## 10. Sincronização, apresentação Android e DMA-BUF de buffers

A série atual tem 22 patches, compartilhados pelas duas ABIs. O patch G925 de
identificação continua separado. A evidência consolidada está no checkout do
driver em `validation/g925-bringup/interop/validation.json`: nove grupos de teste,
18 execuções frias aprovadas, hashes dos artefatos/APKs/fontes e controles falhos
preservados. Não há alegação de conformidade completa ou release DroidDeck.

A exportação SYNC_FD da base anunciava import/export, mas `vkGetFenceFdKHR`
falhava com host OOM no tablet; `/dev/sw_sync` está ausente. Promovemos a
implementação KCPU já existente em `csf-v11/075` para `csf/019`. CQS waits nos
alvos GPU seguidos de FENCE_SIGNAL produzem um sync_file do kernel. O ajuste
em `csf-v11/059` é somente contexto de dependência/assinatura. A série G615
aplica e seis arquivos relevantes são idênticos após a promoção; ainda falta
teste em hardware G615. Nenhuma extensão nova foi habilitada.

Bionic e glibc/public loader/PRoot passaram export/import de fence e semáforo
binário, com FD kernel Mali real, consulta/poll e leitura exata após escrituras
GPU. Uma execução anterior glibc ficou sem APP_END enquanto o framework
registrava Activity sleep. Isso ficou como coleta incompleta. O harness agora
mantém apenas sua janela temporária visível/acordada, registra TEST_BEGIN e
limpa seus próprios resultados antigos; execuções frias posteriores passaram.
Essa correlação não prova a causa no escalonador vendor e não exige root.

A apresentação Android passou 300 frames em cada uma de duas execuções frias.
PixelCopy da superfície ainda viva confirmou canto vermelho `0xffff0000` e
centro azul `0xff0000ff`. O teste negativo destrói somente a SurfaceView do
probe: a base retornava sucesso depois de surfaceDestroyed; o patch genérico
`wsi/017-android-present-errors.patch` agora retorna
`VK_ERROR_SURFACE_LOST_KHR` (-1000000000), mantendo a apresentação normal.
Ele propaga falhas de espera, lock e post e só avança present IDs após sucesso.
**Esse WSI usa cópia e não comprova a arquitetura DMA-BUF final.**

AHB Bionic completou 20 ciclos de allocate/import/draw/fence/readback/destruição
em dois processos de app comum. AHardwareBuffer_lock recebeu o fence exportado;
a leitura usou stride real e limites da alocação. Tanto o AHB quanto o buffer
Vulkan mostraram o triângulo parcial vermelho sobre o clear azul. O escopo é
uma alocação RGBA8 linear; formatos arbitrários, vídeo/protected, AHB entre
processos e SurfaceControl continuam pendentes.

O novo `tests/external-memory/dmabuf-buffer.c` cria dois VkDevice/contextos kbase
independentes. Exporta DMA-BUF real, valida com DMA_BUF_IOCTL_SYNC, consulta os
memory type bits e importa no peer. Barriers EXTERNAL transferem ownership;
fences kernel fazem a passagem de conclusão. A GPU do peer copia para seu
buffer separado de readback: todas as 1.024 palavras precisam corresponder.
A escrita reversa também é feita e lida pela GPU. Bionic passou 20 ciclos e
glibc sob PRoot passou em dois processos frios. São buffers no mesmo processo,
com waits de fence no host; ainda não são imagens ou transporte Bionic–glibc.

Como compilar/testar: os READMEs do checkout PanVK em `tests/external-sync`,
`tests/external-memory`, `tests/ahb`, `tests/android-surface` e
`tests/runtime-loader-app` registram toolchains, modos de Intent, marcadores,
deadlines e remoção dos APKs. NDK 28.2 e GCC13 ARM64 recompilaram os probes com
Wall/Wextra/Werror. As suítes mínimas de ambas as ABIs passaram novamente.
Drivers atuais: `build/g925-artifacts/interop-qualified/{android,glibc}`;
o JSON glibc acompanha a biblioteca. O nome da pasta não é uma garantia de
interoperabilidade completa: usar os escopos e hashes de validation.json.

Possíveis regressões ainda não cobertas: outras versões CSF/UAPI, exportação
JM, lifetime de fences KCPU durante teardown assíncrono, formatos/modifiers
externos e demais erros WSI. Os APKs/dados temporários foram removidos; dmesg
continua negado. Não houve alteração funcional do DroidDeck nem spoofing.

Próximo gate: imagens DMA-BUF/modifiers, transporte entre processos e entre
Bionic/glibc, Wayland DMA-BUF/fences e gamescope no runtime completo. Somente
após esses testes vêm GpuBackend, DXVK, packaging/CI e a matriz VKD3D. A meta
final permanece incompleta.

## 11. Imagens entre Bionic/glibc e contratos gamescope

A continuidade autorizada após a captura está no checkout separado do driver.
`validation/g925-bringup/image-ipc/validation.json` agora qualifica 20 ciclos
em duas execuções frias de app comum. O produtor glibc/public loader/PRoot e
o consumidor JNI Bionic têm contextos kbase/VkDevice persistentes por sequência.
Imagens RGBA8 64×64, modifier LINEAR 0, offset 0, rowPitch 256 e allocation
16384 vêm das consultas reais; metadata e FDs seguem por SCM_RIGHTS.
SO_PEERCRED confirma os UID/PID dos dois processos.

Os deviceUUIDs são iguais e os driverUUIDs das ABIs diferem. O teste usa
FOREIGN_EXT/GENERAL para transferir ownership. Capturas anteriores com EXTERNAL
permanecem diagnósticas e não contam para a qualificação entre ABIs. Dois
sync_file reais do kernel transportam a conclusão da GPU nas duas direções.
Todas as 4096 posições RGBA correspondem ao padrão esperado em cada direção.
O padrão usa render-pass clear/partial clear; este teste não prova sampling
de imagem importada nem substitui o triângulo offscreen já testado.

Arquivos: `tests/external-memory/dmabuf-image-ipc.c`, harness Android, builder
e `qualify-image-ipc.py`. O verificador cruza bytes/hashes do APK e seus drivers,
rootfs e probes, além de UUIDs/PIDs/layout/ciclos. Controles offline de ownership
EXTERNAL, PID incorreto, ciclo ausente e hash de APK incorreto foram rejeitados.
Comandos de build/execução estão no README do teste. Os drivers de 22 patches
permanecem byte-idênticos à qualificação anterior; nenhuma extensão foi habilitada.
O APK temporário foi removido; dmesg continua negado ao shell.

O novo `tests/runtime-features/gamescope-caps.c` captura somente propriedades
PanVK, sem criar VkDevice ou habilitar features. `docs/GAMESCOPE-G925.md` mapeia
gamescope 3.16.29 e wlroots 0.20.2 nos commits fixados. As consultas mostram
hasPrimary=0/hasRender=0 e OPAQUE_FD binário/timeline com features zero; SYNC_FD
binário suporta import/export. Não inventar nós DRM ou syncobj para satisfazer
o consumidor. A extensão física DRM pode legitimamente indicar ausência de nós.

A build upstream ARM64 gamescope passou em container Arch após um include
C++ `<cfloat>` ausente, registrado separadamente em `tests/gamescope/patches`.
DRM continua habilitado no controle; não há patch funcional de backend. Duas execuções frias sob app/PRoot confirmaram seleção PanVK da G925 e
rejeição `physical device has no primary node`, código 1. Evidência em
`validation/g925-bringup/gamescope-baseline/validation.json`; esse é um bloqueio
reproduzido, não aprovação de gamescope. Uma captura anterior com SIGSEGV por
HOME/passwd ausentes no harness está preservada como controle falho; o ambiente
privado do guest foi corrigido sem mudar driver ou backend.
A matriz diferencia extensões/features enumeradas de workloads validados.

Pendências: outros formatos/modifiers, sampling importado, sincronização
assíncrona entre processos, Wayland DMA-BUF/feedback/fences, SurfaceControl e
gamescope na sessão completa. GpuBackend, DXVK, VKD3D-GAPS e CI/pacotes
continuam no objetivo final; nenhum deles foi declarado concluído.

## 12. Wayland entre ABIs, shader sampling e avanço gamescope

O novo `tests/wayland-dmabuf` no checkout PanVK executa servidor libwayland
Bionic via JNI e cliente glibc/public loader/PRoot sob o mesmo UID de app real,
em processos diferentes. A negociação usa linux-dmabuf v3, que gamescope
3.16.29 fixa em seu backend Wayland. O servidor anuncia apenas o formato e
modifier consultados, sem inventar nó DRM para feedback v4.

Passaram 20 frames em duas execuções frias: RGBA8/ABGR8888 LINEAR, allocation
16384, offset 0 e stride 256. Acquire/release seguem pelo protocolo padrão
linux-explicit-synchronization v2 com sync_file do kernel; o protocolo mais
novo DRM syncobj continua pendente. Um shader compute Bionic texelFetch da
imagem importada escreve o buffer de readback: todos os 4096 pixels correspondem.
O servidor escreve verde na GPU e o cliente confirma todos os pixels após
o release fence. FOREIGN e as relações UID/PID/UUID são verificadas.

`validation/g925-bringup/wayland-dmabuf/validation.json` cruza bytes/hashes de
APK/rootfs/drivers/client e das bibliotecas Wayland/ffi já existentes no
DroidDeck. Os drivers não mudaram. O verificador rejeita ausência de sampling,
release, peer PID incorreto e layout alterado. Os READMEs registram geração
de protocolos/SPIR-V, builds GCC/NDK com Werror, execução e cleanup.
O APK temporário foi removido, sem root ou mudança de bibliotecas do sistema.

Depois desse controle, patches genéricos gamescope 002/003 permitem ausência
real de nós em backends sem sessão DRM e alinham presentId/presentWait às
extensões solicitadas. O caminho de sessão/nós existentes é preservado; não
há if(mali) nem fd kbase fingindo syncobj. Os patches reconstruíram os arquivos
com git apply --index e compilaram. Em dois processos frios, gamescope passou
o gate de nós, criou VkDevice, consultou formatos/alocou output e iniciou o
compositor headless. Xwayland abortou por falta de XKB e libEGL no rootfs
mínimo; o harness terminou com timeout124. Evidência em `gamescope-nodes`.
Esse avanço parcial não é aprovação de frames ou runtime completo.

Próximo passo: completar a closure de recursos reais do controle e validar
clientes/frames. Permanecem contratos wlroots sem DRM, timelines externas,
compositor completo/Surface Android, outros formatos/modifiers e regressão
Adreno em hardware. Runtime/compositor DroidDeck continuam sem alterações
funcionais; GpuBackend, DXVK, VKD3D-GAPS e CI/pacotes seguem no objetivo final.


## 13. Recursos de runtime e candidato wlroots/gamescope sem DRM

A captura posterior com EGL confirmou outra diferença do rootfs de diagnóstico:
o Activity não fornecia /dev/shm privado, já previsto no LinuxRuntime do
DroidDeck. Nos dois processos, UID 10492/PIDs 8618 e 9259, wlroots falhou em
shm_open/keymap e Xwayland tentou fallback de glamor para software; ambos
terminaram em timeout124. Não há aprovação de GL/Zink ou frames gamescope.

O harness agora passa um diretório privado por PRoot e a closure inclui XKB,
seu symlink relativo de compatibilidade, fontes e plugins EGL/DRI. O teste
isolado no host usa a implementação shm do wlroots fixado, muda apenas as
credenciais do filho do container para UID/GID 65534 e testa SHM, compilação
real de keymap e dlopen sem criar display/context EGL. Dois processos frios
passaram; remover cada um de três recursos produziu a falha esperada. Isso
não comprova execução Android/PRoot, autorização no tablet ou rendering.

Uma API genérica separada em wlroots cria linux-dmabuf v1–v3 a partir dos
formatos fornecidos, com cópia do set e callback obrigatório de importação.
Não fabrica main_device/dev_t ou feedback v4. Em dois processos frios, o teste
Wayland de protocolo anunciou v3 e rejeitou 30 memfds comuns inválidos em cada
execução, sem vazamento; stride inválido foi rejeitado antes do callback.
Os buffers são fixtures negativas do host, não DMA-BUFs G925 validados.

Os patches gamescope 004/005 usam essa API só quando falta fd DRM, verificam
importação real Vulkan antes de aceitar wl_buffer e não publicam DRM syncobj
sem fd DRM. As cinco mudanças gamescope e a mudança wlroots reconstruíram
exatamente seus arquivos a partir das revisões fixadas e compilaram. Não há
patch novo no ICD, profile/modelo G925, runtime ou compositor DroidDeck.

A closure agora inventaria dados, modos e symlinks; tar/gzip normalizados a
partir do timestamp do commit Mesa produziram duas vezes os mesmos bytes.
Isso comprova repetição do empacotamento desses inputs, não reproducibilidade
completa de builds/toolchains. O APK de controle foi compilado/assinado e seus
bytes de rootfs/ICD foram verificados. O runner novo recusa aparelho ausente
ou package existente e foi testado com falha de launch/cleanup simulada.

O reteste real parou no preflight ADB, antes da instalação: RX2Y9010N5Y não
estava conectado. Evidências, patches, comandos e limites ficam em
`tests/gamescope/README.md` e
`validation/g925-bringup/gamescope-legacy-dmabuf/` no checkout do driver.
O controle usa /usr/bin/true: mesmo exit0 aprovará apenas bootstrap, não frames.

Próximo gate: importar/lifetime no hardware, private shm/Xwayland em PRoot,
sincronização sem DRM e frames gamescope/Surface Android reais; depois runtime
completo e regressão Adreno. GpuBackend, Steam/DXVK, VKD3D-GAPS e CI/pacotes
continuam no objetivo final, sem antecipar aprovação. Nenhuma capability ou
extensão Vulkan foi acrescentada para satisfazer aplicações.

## 14. Reteste conectado e correção do controle gamescope

O retorno exit1 vazio de `pm path` para pacote ausente causava o falso bloqueio
`existing-package:`. O runner agora confirma ausência por uma consulta válida
à lista de pacotes, mantendo proteção para pacote existente e erros ADB.
Os testes cobrem ausência, nome exato, respostas inválidas e erros de acesso.

Com o Tab conectado, o reteste avançou pela enumeração PanVK e global DMA-BUF.
O rootfs de diagnóstico precisava de /bin/sh para o Popen do xkbcomp e de uma
entrada passwd para o UID real, exigida pela autorização local do Xwayland.
Apenas o guest privado da Activity temporária recebeu passwd/group; nenhuma
conta, permissão ou configuração Android foi alterada. A receita também inclui
gamescopereaper, ausente no primeiro controle bem-sucedido.

Duas execuções frias UID10496/PIDs19943 e 20115 passaram o bootstrap headless
com /usr/bin/true. O APK foi removido e ausência confirmada. Isso não valida
frames gamescope, cliente DMA-BUF, sincronização ou apresentação Android.
Glamor usou fallback software. Os bytes dos drivers e patches G925 permanecem
inalterados. Evidências e falhas anteriores preservadas no checkout PanVK em
validation/g925-bringup/gamescope-bootstrap/. O próximo gate continua sendo
composição de frames reais antes da integração GpuBackend no DroidDeck.

## 15. Frames DMA-BUF dentro do gamescope: progresso e DeviceLost

Um cliente glibc novo criou toplevel xdg-shell, exportou imagens DMA-BUF reais
e solicitou capturas FULL_COMPOSITION ao gamescope. O produtor espera seu
sync_file antes do commit; esse teste não aprova fencing assíncrono. O
compositor Vulkan produziu 23 capturas com todos os 4096 pixels corretos em
padrões alternados. A saída é headless, sem apresentação Surface Android.

A alocação da captura inicialmente causou SIGSEGV: gamescope solicitava memória
visível/coerente/cached e não verificava o retorno -1 da seleção. A tabela
PanVK observada tem flags 0x1, 0x7 e 0xb. O patch genérico gamescope 006 torna
cache preferência, conserva coerência e rejeita seleção inválida. Compilou e
os seis patches reconstruíram exatamente os fontes fixados. O PanVK, o
profile G925 e o runtime/compositor DroidDeck não mudaram nesta correção.

O gate de estabilidade ainda falhou: depois das seis capturas iniciais, uma
execução fria completou dez e a outra apenas sete, com timeout nas filas CSF,
DEVICE_LOST e SIGABRT. Com a instrumentação existente kbase_diag, duas sequências
de dez completaram. Esse modo muda stores/esperas/timing e não é aprovação.
Não atribuir a causa à região de cache flush apenas pelo cursor CS_EXTRACT.
Evidências, reproducer, stacks e comparação estão no checkout PanVK em
validation/g925-bringup/gamescope-composition/. APKs temporários foram removidos;
não houve root, alteração de sistema ou novas capabilities.

O teste isolado de timeline/fila completou 11.800 submissões sem debug: fill,
graphics, janela de oito submissões pendentes com marcador GPU, e recursos
recriados a cada frame com padrões alternados. Todos tiveram readback exato;
a falha gamescope não foi reproduzida. Inclui 4.000 submissões com command pool
reutilizado e outras 4.000 com shader compute amostrando a imagem nesse mesmo
caso. Fontes e evidência por controle estão
em validation/g925-bringup/queue-timeline/ no checkout PanVK.

Duas novas execuções gamescope sem debug completaram 20 capturas cada, com
pixels exatos. O controle separado no_wb_mmap também completou 40. A falha
anterior é intermitente; esses resultados não identificam a causa nem aprovam
estabilidade. O teste foi ampliado para sequências de até 100 frames:

| Controle | Capturas exatas nos dois processos | Resultado |
|---|---|---|
| Sem debug | 21 / 100 | DeviceLost no primeiro |
| no_wb_mmap | 100 / 100 | Diagnóstico completo; não qualifica produção |
| no_user_mmap_sync | 40 / 100 | DeviceLost no primeiro |
| sync | 100 / 100 | Diagnóstico completo; não qualifica produção |

Próximo passo: isolar compartilhamento entre dispositivos Vulkan e sobreposição
de trabalho com recursos cached reutilizados, reproduzindo a falha gamescope;
depois apresentação Wayland/Android e runtime completo, antes de GpuBackend,
Steam/DXVK e CI. Nenhuma mudança funcional DroidDeck nesta investigação.

[panvk]: https://github.com/zenithblue-oss/panvk-kbase-android
[issue165]: https://github.com/Droid-Deck/DroidDeck/issues/165
[p-lock]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/sources.lock#L1
[p-apply]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/scripts/apply-patches.sh#L13
[p-profiles]: https://github.com/zenithblue-oss/panvk-kbase-android/tree/de577411e8f27da9de50aec26a0d8cc43890745e/profiles
[p-changelog]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/CHANGELOG.md#L3
[p-readme]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/README.md#L72
[p-architectures]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/docs/MALI-GPU-ARCHITECTURES.md#L204
[p-patches]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/README.md#L1
[p-enumerate]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/005-instance-enumerate.patch#L43
[p-physical]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/004-physical-device-kbase.patch#L846
[p-device]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/006-device-queue-wsi-kbase.patch#L183
[p-kmod-init]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L1127
[p-kmod-props]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L182
[p-kmod-csif]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L402
[p-kmod-groups]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L510
[p-kmod-memory]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L1439
[p-kmod-cache]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L1852
[p-kmod-ops]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/files/src/panfrost/lib/kmod/kbase_kmod.c#L2011
[p-sync]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/004-physical-device-kbase.patch#L787
[p-syncfd]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/csf-v11/075-export-kbase-sync-file-fences-through-a-kcpu-queue.patch#L1
[p-csf-submit]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/csf/007-gpu-queue-kbase.patch#L1722
[p-wsi]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/006-device-queue-wsi-kbase.patch#L269
[p-architecture]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/docs/ARCHITECTURE.md#L1
[p-build-android]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/scripts/build-android.sh#L6
[p-build-glibc]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/scripts/build-glibc.sh#L40
[p-package-android]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/scripts/package-android-adpkg.sh#L24
[p-package-glibc]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/scripts/package-glibc.sh#L17
[p-tests]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/tests/README.md#L1
[m-meson]: https://gitlab.freedesktop.org/mesa/mesa/-/blob/5a07217f034b3e50d8c7c7794f97a2df1742613b/src/panfrost/vulkan/meson.build#L81
[m-dispatch]: https://gitlab.freedesktop.org/mesa/mesa/-/blob/5a07217f034b3e50d8c7c7794f97a2df1742613b/src/panfrost/vulkan/panvk_macros.h#L45
[p-dispatch]: https://github.com/zenithblue-oss/panvk-kbase-android/blob/de577411e8f27da9de50aec26a0d8cc43890745e/patches/kbase-common/004-physical-device-kbase.patch#L936
[d-activity]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/SessionActivity.kt#L927
[d-host]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/wayland/CompositorHost.kt#L29
[d-turnip]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/gpu/TurnipDriver.java#L248
[d-jni]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/waylandcomp_jni.c#L253
[d-loader]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/vk_loader.c#L17
[d-linux-manager]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/gpu/LinuxVulkanDriverManager.java#L181
[d-service]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/session/SessionService.kt#L552
[d-session]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/linuxfs/overlay/usr/local/bin/droiddeck-session#L59
[d-desktop]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/linuxfs/desktop/droiddeck-desktop#L24
[d-bundle]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/gpu/DriverBundle.kt#L44
[d-gpuinfo]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/gpu/GpuInfo.kt#L55
[d-runtime]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/runtime/LinuxRuntime.java#L286
[d-bwrap]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/runtime/BwrapSpawner.kt#L228
[d-stats]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/session/GpuStatsComponent.kt#L50
[d-memory]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/session/GpuMemComponent.kt#L84
[d-clocks]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/java/com/droiddeck/launcher/session/GpuClockPin.kt#L20
[d-drm-preload]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/linuxfs/preload/drm.c#L1
[d-id-preload]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/linuxfs/preload/kgslid.c#L1
[d-poll-preload]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/linuxfs/preload/kgslpoll.c#L1
[d-compositor]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/compositor.c#L761
[d-present]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/vk_present.c#L934
[d-ahb]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/ahb_swapchain.c#L275
[d-ahb-fences]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/ahb_swapchain.c#L132
[d-layer]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/app/src/main/cpp/waylandcomp/src/sc_layer.c#L110
[d-wlroots]: https://github.com/Droid-Deck/DroidDeck/blob/da29919b5a92e66523d55570960607eef35d1201/tools/wlroots/patches/0001-vulkan-allocator-for-non-drm-gpu-nodes.patch#L132
[r-android]: https://github.com/Droid-Deck/Drivers/blob/27bf2ac1b386ac3399a7a5604ead18f067f652c3/scripts/build_android.sh#L1
[r-linux]: https://github.com/Droid-Deck/Drivers/blob/27bf2ac1b386ac3399a7a5604ead18f067f652c3/scripts/build_linux.sh#L1
[r-series]: https://github.com/Droid-Deck/Drivers/blob/27bf2ac1b386ac3399a7a5604ead18f067f652c3/patches/series.json#L1
[r-package]: https://github.com/Droid-Deck/Drivers/blob/27bf2ac1b386ac3399a7a5604ead18f067f652c3/scripts/package_bundle.py#L20
[r-readme]: https://github.com/Droid-Deck/Drivers/blob/27bf2ac1b386ac3399a7a5604ead18f067f652c3/README.md#L1
