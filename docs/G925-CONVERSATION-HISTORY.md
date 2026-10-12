# Histórico técnico da conversa — DroidDeck no Galaxy Tab S11

Registro consolidado em 2026-10-12. Este documento resume as solicitações,
decisões e resultados disponíveis da conversa; não é uma transcrição literal.
As evidências de hardware e experimentos mantêm suas datas originais,
principalmente 2026-10-05 e 2026-10-06.

## Objetivo e limites acordados

Executar jogos de computador no Galaxy Tab S11 com Dimensity 9400+ e
Immortalis-G925, usando PanVK sobre o mali_kbase proprietário. A base principal
é panvk-kbase-android; não desenvolver um driver Vulkan do zero.

Arquitetura desejada: compositor Android → PanVK Bionic → /dev/mali0;
runtime Linux ARM64 → gamescope/Steam/Proton/DXVK → ICD PanVK glibc → /dev/mali0.
Os dois drivers devem compartilhar a base Mesa e os patches quando possível.

Restrições mantidas durante o trabalho:

- Obter IDs, revisões, ABI e capacidades do hardware ou de fontes verificáveis.
- Não fazer feature spoofing nem anunciar extensões apenas para satisfazer jogos.
- Preservar uso sem root; não substituir bibliotecas proprietárias do Android.
- Isolar patches G925 das correções genéricas e preservar o caminho Adreno.
- Validar standalone, glibc e gamescope antes de integrar runtime/compositor.
- Priorizar DXVK/D3D9–11; D3D12/VKD3D-Proton não é requisito inicial.
- Testes posteriores usam apps e arquivos temporários, removidos ao concluir.
  O coletor inicial é exclusivamente de leitura.

## Solicitações e evolução do escopo

1. O usuário especificou fases de investigação, coleta, profile, Vulkan Bionic,
   glibc, gamescope, integração DroidDeck e DXVK. A primeira entrega foi limitada
   a `docs/G925-BRINGUP.md` e `tools/collect-g925-info.sh`.
2. O plano de implementação detalhou revisões fixadas, contratos dos drivers,
   coleta tolerante a erros, testes simulados e coleta real sem root.
3. O trabalho avançou para probes nativos, profile sustentado por evidências,
   builds e testes standalone Bionic/glibc e interoperabilidade.
4. O usuário reportou `Control stopped: existing-package:` ao executar o runner
   de gamescope. A investigação identificou a resposta vazia com status 1 de
   `pm path` para pacote ausente; a correção exige confirmação independente
   bem-sucedida por `pm list packages --user current`. Falhas de transporte ou
   permissão não são tratadas como ausência. Uma instalação existente continua
   protegida contra substituição acidental.
5. O usuário esclareceu que o objetivo é desenvolvimento legítimo para jogar no
   próprio tablet e pediu continuidade até um DroidDeck funcional. O trabalho
   continuou com experimentos de composição e isolamento do DeviceLost.
6. Em 2026-10-12, pediu publicar todas as mudanças no Git e este histórico.
   A publicação registra também falhas e trabalho ainda não validado.

## Bases analisadas

| Projeto | Revisão |
|---|---|
| DroidDeck | `da29919b5a92e66523d55570960607eef35d1201` |
| Drivers, somente referência | `27bf2ac1b386ac3399a7a5604ead18f067f652c3` |
| panvk-kbase-android | `de577411e8f27da9de50aec26a0d8cc43890745e` |
| Mesa fixado | `5a07217f034b3e50d8c7c7794f97a2df1742613b` |
| gamescope 3.16.29 | `8f212644c46460549035971ab914421180f61a7c` |
| wlroots | `d783533489e1f75d6886c2ab5c5960090ef268f8` |

A análise inicial cobre profiles, identificação/UAPI, memória, submission/sync,
builds, testes e os contratos Turnip/KGSL, instalação de bundles, ICDs e frames
do DroidDeck. A issue [DroidDeck #165](https://github.com/Droid-Deck/DroidDeck/issues/165)
contextualiza a necessidade de suporte a GPUs não-Adreno.

## Hardware observado, sem root

| Campo | Evidência |
|---|---|
| Tablet | SM-X730 / gts11wifi, plataforma MT6991 |
| Sistema | Android 16 / API 36 |
| Kernel | `6.6.102-android15-8-abogkiX730XXS9BZI1-4k` |
| SELinux | Enforcing; testes também sob UID real de app / untrusted_app |
| Nó | /dev/mali0; abertura e ioctls confirmados no aplicativo |
| RAW_GPU_ID kbase | `0xd8300015` |
| ID Vulkan proprietário | `0xd8300010`, distinto do RAW_GPU_ID |
| Product / variant | `0xd830` / 4 |
| Arquitetura no Mesa fixado | v13; correspondência com modelo compartilhado G725 |
| kbase CSF UAPI | 1.30 |
| Interface global CSF | `0x030a0000` (3.10); não é versão DDK ou release do firmware |
| Topologia | 12 shader cores; máscara `0xee0077`; páginas 4 KiB |
| Grupos/streams | 8 grupos, 64 streams, 8 por grupo |
| Suspend buffer / stream features | 27.712 bytes / `0x0007107f` |
| DDK proprietário | `v1.r49p1-03bet0.f8a98b506b89b21c80a508d70abfcb3f` |

A divergência entre VERSION_STATUS=0 e o nibble de status 5 no RAW_GPU_ID
permanece registrada sem atribuir uma explicação vendor não comprovada.
O modelo compartilhado não prova equivalência G725/G925. Capacidades do driver
proprietário não foram transferidas para PanVK. dmesg e alguns atributos sysfs
negaram acesso ao shell; isso não motivou root.

## Implementação e resultados registrados

### Investigação e diagnóstico

O documento de bring-up está em português, com referências fixadas. O coletor
Bash/Python 3 usa biblioteca padrão e ADB, escolhe o dispositivo explicitamente,
recusa saída existente, limita tempo/tamanho e preserva erros por consulta.
Não instala nada nem executa novos ioctls. Relatórios completos ficam locais.

### Profile e drivers standalone

O profile `g925-v13-csf-uapi1.30.json` registra os valores medidos. A mudança de
identificação v13 é isolada e usa o ID/variant exatos. Correções genéricas de
lifetime CRC e exportação sync_file foram promovidas para famílias comuns;
o tratamento de erro SurfaceLost permanece separado em WSI.

A série qualificada chegou a 22 patches. Instância, enumeração, dispositivo,
compute, offscreen e sincronização passaram em Bionic e glibc. O ICD glibc foi
testado com loader público, JSON explícito e PRoot sob o UID real do app.
A API 1.4.363 reportada não é certificação de conformidade Vulkan.

Hashes dos drivers qualificados mantidos nos controles seguintes:

- Bionic SHA256: `b4ef205c364d9405e4c4722c0d28b4504e4ffbe92832534fa213b157f435390b`.
- glibc SHA256: `41f90324dc72eb3322194d01ccf8d54f9bba5c898f752f6cb7e880dce16bb0ed`.

### Interoperabilidade e apresentação

- Android WSI: 600 frames, PixelCopy e controle negativo SurfaceLost.
- AHB: 20 triângulos reais com fences e leitura de pixels.
- Wayland/vkcube: 600 frames em Weston headless/Pixman por cópia/SHM;
  esse resultado não qualifica o caminho completo DMA-BUF.
- Export/import de sync_file reais e compartilhamento de buffers DMA-BUF.
- 20 ciclos de imagens entre Bionic/glibc, ownership FOREIGN, SCM_RIGHTS,
  fences reais e comparação dos 4096 pixels em ambas as direções.
- 20 ciclos Wayland linux-dmabuf v3 e explicit synchronization v2 com sampler
  compute; esse teste isolado não possui a saída Android do compositor final.

### gamescope e erro existente

Seis patches locais genéricos de gamescope e um de wlroots adaptam caminhos
que dependiam de DRM: nós obrigatórios apenas para sessão DRM, seleção de
features presentId/presentWait, linux-dmabuf v3 sem feedback DRM inventado,
publicação de syncobj somente com DRM real e seleção válida de memória.
Há também uma correção de include para compilação. As revisões foram
reconstruídas e compiladas; regressão em hardware Adreno ainda não foi feita.

Uma falha SIGSEGV foi isolada: o consumidor passava memoryTypeIndex=UINT32_MAX
quando não existia memória simultaneamente HOST_VISIBLE|HOST_COHERENT|HOST_CACHED.
Os flags reais observados foram 0x1/0x7/0xb. O patch preserva coerência, prefere
cache quando disponível e rejeita ausência de um tipo válido antes da alocação.

A composição real recebe xdg-shell + DMA-BUF e é exercitada por capturas
FULL_COMPOSITION do gamescope. Cada captura compara 4096 pixels. O produtor
aguarda seu sync_file antes do commit; fencing assíncrono completo ainda não
está qualificado. Headless não apresenta os frames na superfície Android.

Persistiu DeviceLost intermitente: timeout de filas CSF, vkWaitSemaphores=-4
e SIGABRT. CS_EXTRACT mostra fetch; não identifica a instrução onde a GPU parou.

| Controle de 100 frames | Capturas corretas por processo frio | Resultado |
|---|---|---|
| Sem debug | 21 / 100 | DeviceLost no primeiro processo |
| no_wb_mmap | 100 / 100 | Passou somente como controle diagnóstico |
| no_user_mmap_sync | 40 / 100 | DeviceLost no primeiro processo |
| sync | 100 / 100 | Passou somente como controle diagnóstico |

Controles menores de 20+20 também passaram sem debug; não anulam a falha longa.
kbase_diag altera execução/conclusão e é excluído da qualificação, assim como
os controles de cache/sync. Nenhuma dessas opções foi promovida a solução para jogos.

Os testes isolados de filas/timelines totalizaram 11.800 submissões corretas,
sem debug: fill, graphics, janela de oito submissões, recriação de recursos,
reset de command pool e reset com sampler compute/dois readbacks. Não
reproduziram a falha do gamescope. Os resultados estão em validation/g925-bringup.

### Trabalho mais recente ainda não qualificado

Foi adicionada a opção diagnóstica `--validation-layer` ao empacotamento e ao
runner. O app configura a layer Khronos e sincronização somente no ambiente
privado do guest; a opção não conta como validação de produção. A layer foi
preparada no container ARM64 do computador. Esse novo caminho ainda não foi
executado/qualificado no tablet. Não confundir preparação do pacote com teste
concluído. O reproducer de compartilhamento entre VkDevices com trabalho
sobreposto ainda está por implementar.

## Estado na publicação

**Ainda não há um DroidDeck G925 pronto para jogar.** O runtime/compositor
DroidDeck não recebeu alterações funcionais. Steam/Proton/DXVK, a abstração
GpuBackend, integração final, CI reprodutível e release continuam pendentes.
O bloqueio imediato é obter composição gamescope estável e explicar/corrigir
o DeviceLost com um reproducer mínimo e evidências de sincronização.

Os arquivos publicados incluem fontes, patches e evidências selecionadas.
Builds, APKs, bibliotecas .so, rootfs, chaves e relatórios Android brutos ficam
fora do Git. Capturas PNG de padrões sintéticos são evidências, não binários
executáveis. `publication-logcat-extracts.json` registra a filtragem dos logs:
linhas de outros aplicativos foram omitidas; os originais permanecem locais.
Hashes históricos desses logs referem-se às capturas originais, e o manifesto
fornece separadamente os hashes dos extratos publicados.

Publicação solicitada pelo usuário, em branches `codex/g925-bringup` dos forks:

- [viniblopes/DroidDeck](https://github.com/viniblopes/DroidDeck/tree/codex/g925-bringup): análise, coletor e histórico.
- [viniblopes/panvk-kbase-android](https://github.com/viniblopes/panvk-kbase-android/tree/codex/g925-bringup): profile, patches, ferramentas, testes, evidências e cópia deste histórico.

Os remotes upstream são preservados. Esta publicação não é um release e não
faz merge nos projetos originais.

## Retomada e comandos úteis

No checkout DroidDeck, com o tablet conectado ao computador:

```sh
adb devices -l
bash tools/collect-g925-info.sh --serial SERIAL_ADB --output g925-device-report
tar -czf g925-device-report.tar.gz g925-device-report
```

Use um diretório de saída novo. Não publique o relatório bruto sem revisar
dados de aplicativos e identificadores. O coletor não precisa de root.

No checkout PanVK, os testes de regressão do runner executam apenas no host:

```sh
python3 tests/gamescope/test-package-query.py
python3 tests/gamescope/test-capture-pixels.py
```

Consulte `validation/g925-bringup/README.md`, `docs/GAMESCOPE-G925.md` e os
READMEs dos testes para receitas completas e identificação dos artefatos.
Antes de um teste no tablet, APK e rootfs precisam corresponder entre si e
ao hash do driver qualificado. O ID esperado PanVK é o RAW_GPU_ID medido,
`0xd8300015`; não usar o deviceID do driver proprietário em seu lugar.

Próximo passo técnico: executar a instrumentação de validação separadamente,
depois isolar compartilhamento de imagens entre dispositivos/contextos com
trabalho sobreposto e fences reais. Só após a correção e repetição estável dos
controles avançar para apresentação Android e integração DroidDeck.
