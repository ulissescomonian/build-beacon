# Build Beacon — plano de implementação

**Status:** Preview 1.0.0 empacotada; distribuição Apple de produção ainda bloqueada por gates externos
**Data-base:** 21 de julho de 2026
**Documento de decisões:** `docs/discussion.md`

## 1. Objetivo do plano

Entregar uma aplicação nova, própria e nativa para macOS que monitora pipelines
do Bitbucket Cloud com segurança, sem falso estado saudável, sem polling
duplicado e sem dependências de runtime não nativas.

Este plano transforma cada decisão arquitetural em trabalho implementável,
critério de aceite e evidência de validação. Ele não autoriza cópia de código,
texto, marca, UI ou assets de aplicativos analisados. O repositório será criado
em clean-room a partir dos requisitos próprios registrados em
`docs/discussion.md`.

## 2. Premissas de execução

- Swift 6 com strict concurrency;
- SwiftUI como UI principal e AppKit apenas em integrações macOS que o exijam;
- macOS 14 como deployment target inicial;
- build universal arm64 + x86_64 até decisão explícita em contrário;
- Bitbucket Cloud como único provider do 1.0;
- API Token, e-mail Atlassian e Keychain;
- 1.0 somente leitura; ações remotas ficam em spike pós-1.0;
- zero pacotes de runtime de terceiros no MVP; Xcode/SDK, CI, scripts,
  certificados e host de release continuam no threat model;
- distribuição direta assinada e notarizada é requisito do release público;
- português e inglês preparados por String Catalog, ainda que o primeiro beta
  entregue apenas um idioma revisado;
- o código está organizado como Swift Package nativo; Git, CI público e
  credenciais de notarização não foram criados implicitamente.

## 3. Resultado esperado do 1.0

Ao final, uma pessoa deve conseguir:

1. instalar o app sem contornar o Gatekeeper;
2. conectar sua conta com API Token armazenado no Keychain;
3. selecionar workspace, projeto, repositório e branch;
4. enxergar saúde confiável na menu bar;
5. distinguir sucesso, execução, aprovação, falha, stale e indisponibilidade;
6. abrir um dashboard com execução e etapas;
7. receber uma notificação por transição relevante;
8. atualizar manualmente sem duplicar requests;
9. configurar intervalo, notificações e início no login;
10. desconectar e remover integralmente sua credencial.

## 4. Princípios de gestão do trabalho

### 4.1 Planejar antes de editar

Cada milestone começa com:

- contrato de dados estabilizado;
- paths com ownership explícito;
- dependências e hotspots identificados;
- testes esperados descritos;
- decisão sobre feature flag e migração;
- comando de validação conhecido.

### 4.2 Ownership e hotspots

Em cada onda, um path gravável tem um único owner. O integrador é o único que
altera:

- `BuildBeacon.xcodeproj/**`;
- configurações de raiz;
- entitlements;
- `Info.plist` ou build settings equivalentes;
- `Resources/Localizable.xcstrings`;
- workflows de CI;
- lockfiles/arquivos gerados;
- documentação central;
- estado Git, commits, tags e branches.

Owners de domínio, API, infraestrutura e features enviam solicitações ao
integrador quando precisam de mudança nesses hotspots.

### 4.3 Definição de pronto para iniciar

Uma tarefa está `ready` quando:

- requisito e non-goal estão claros;
- dependências anteriores passaram seus gates;
- arquivos têm owner;
- contrato público está documentado;
- fixtures necessárias existem ou estão previstas;
- critérios de aceite são verificáveis;
- nenhum segredo real é necessário em teste automatizado.

### 4.4 Definição de concluído

Uma tarefa só está concluída quando:

- implementação e testes estão no mesmo diff;
- Swift 6 strict concurrency compila sem warnings novos;
- testes específicos passam;
- acessibilidade foi considerada;
- logs e erros estão sanitizados;
- documentação afetada foi atualizada;
- diff foi revisado pelo owner e por revisor independente;
- nenhum TODO crítico foi silenciosamente adiado.

## 5. Estrutura de repositório inicialmente planejada

```text
build-beacon/
├── BuildBeacon.xcodeproj/
├── BuildBeacon/
│   ├── App/
│   ├── Domain/
│   │   ├── Models/
│   │   ├── Policies/
│   │   └── Ports/
│   ├── Application/
│   │   ├── Monitoring/
│   │   ├── Onboarding/
│   │   └── State/
│   ├── BitbucketAPI/
│   │   ├── Authentication/
│   │   ├── DTO/
│   │   ├── Endpoints/
│   │   ├── Mapping/
│   │   └── Transport/
│   ├── Infrastructure/
│   │   ├── Credentials/
│   │   ├── Persistence/
│   │   ├── Notifications/
│   │   ├── LoginItem/
│   │   ├── Links/
│   │   └── Logging/
│   ├── Features/
│   │   ├── MenuBar/
│   │   ├── Onboarding/
│   │   ├── MonitorSelection/
│   │   ├── Dashboard/
│   │   ├── PipelineDetail/
│   │   └── Settings/
│   └── Resources/
├── BuildBeaconTests/
│   ├── Domain/
│   ├── Application/
│   ├── BitbucketAPI/
│   ├── Infrastructure/
│   ├── Fixtures/
│   └── Support/
├── BuildBeaconUITests/
├── Config/
├── scripts/
└── docs/
```

Não extrair Swift Packages prematuramente. Primeiro provar fronteiras com access
control e testes; extrair apenas quando houver benefício mensurável.

### 5.1 Estrutura adotada

Durante M1 foi adotado um Swift Package modular, aberto e compilável nativamente
pelo Xcode, com os seguintes roots:

```text
Sources/BuildBeaconKit/{Contracts,Domain,Application,API,Infrastructure}
Sources/BuildBeaconUI/{views,model,resources}
Sources/BuildBeaconApp/{app,composition-root}
Tests/BuildBeaconKitTests/{Domain,Application,API,Infrastructure}
Tests/BuildBeaconUITests/
Config/
scripts/
docs/
```

A estrutura preserva as fronteiras previstas. A diferença é governada: os
módulos SwiftPM tornam dependências explícitas e eliminam um `.xcodeproj` gerado,
mas ainda não substituem um target XCUITest hospedado nem os gates de archive e
notarização do M10.

## 6. Mapa de milestones

| Milestone | Resultado | Dependência | Gate principal |
|---|---|---|---|
| M0 | decisões fechadas e backlog rastreável | nenhuma | perguntas P0 respondidas |
| M1 | shell macOS nativo compilando | M0 | build/test limpos |
| M2 | domínio e políticas puras | M1 | tabelas de estado exaustivas |
| M3 | transporte Bitbucket robusto | M2 | contract tests sem rede real |
| M4 | credencial e configuração seguras | M2–M3 | token só no Keychain |
| M5 | onboarding e seleção completos | M3–M4 | paginação/branch/erros UI |
| M6 | motor de monitoramento confiável | M2–M5 | single-flight + TestClock |
| M7 | menu bar e dashboard nativos | M5–M6 | estado consistente nas superfícies |
| M8 | notificações e ação manual avaliada | M6–M7 | exatamente uma notificação/transição |
| M9 | ajustes, login item e polimento | M7–M8 | acessibilidade e eficiência |
| M10 | distribuição e release | todas | assinatura, notarização e QA limpo |

## 7. M0 — decisões, governança e baseline

### Objetivo

Impedir que decisões caras sejam tomadas implicitamente durante o código.

### Ownership

- integrador: `docs/**`, raiz, Git e futura configuração Xcode;
- produto: requisitos e decisões de UX;
- segurança/API: autenticação, scopes e ação manual.

### Tarefas

#### M0-01 — fechar decisões de produto

Responder e registrar:

- macOS mínimo;
- Intel no 1.0;
- idioma(s) do 1.0;
- persistência ou não do último snapshot;
- distribuição direta versus App Store;
- prioridade visual de awaiting approval.

**Aceite:** respostas viram ADRs curtas, não ficam apenas em conversa.

#### M0-02 — política clean-room

- manter os requisitos autocontidos;
- proibir cópia de código, textos e assets;
- exigir justificativa própria em PRs;
- criar checklist de review.

**Aceite:** todo contributor consegue trabalhar sem acessar o app analisado.

#### M0-03 — confirmar contratos Bitbucket

- validar autenticação API Token em conta de teste;
- enumerar scopes por endpoint;
- validar como baseline `read:user:bitbucket`, `read:workspace:bitbucket`,
  `read:repository:bitbucket` e `read:pipeline:bitbucket`, removendo qualquer
  scope que o contrato final não exija;
- confirmar paginação de workspaces, repos, pipelines, branches/refs e steps;
- derivar projetos da metadata de repositórios até que uma listagem pública seja
  comprovada;
- confirmar filtro de branch suportado;
- investigar se trigger de etapa é endpoint público e suportado;
- registrar comportamento real de 401, 403, 404 e 429;
- salvar fixtures redigidas, nunca respostas com dados reais.

**Aceite:** uma tabela endpoint → método → scope → paginação → idempotência →
status esperados está aprovada.

#### M0-04 — inicializar governança técnica

- iniciar Git apenas quando autorizado;
- `.gitignore` para Xcode, DerivedData e segredos;
- template de PR com testes, acessibilidade, segurança e screenshots;
- convention de commits e branches;
- nenhum segredo em `.xcconfig` versionado.

**Gate M0:** nenhuma dúvida P0 bloqueia fundação; ação manual pode virar spike
explicitamente fora do 1.0.

## 8. M1 — fundação macOS nativa

### Objetivo

Criar o menor app nativo executável, testável e distribuível sem implementar
Bitbucket prematuramente.

### Ownership

- integrador: projeto, schemes, build settings, entitlements e resources;
- app shell owner: `BuildBeacon/App/**`;
- UI shell owner: placeholders em `BuildBeacon/Features/**`.

### Tarefas

#### M1-01 — projeto Xcode

- criar macOS App SwiftUI;
- Swift language mode 6;
- deployment target definido em ADR-001;
- bundle ID e Team ID congelados antes de Keychain/container/login item;
- targets `BuildBeacon`, `BuildBeaconTests`, `BuildBeaconUITests`;
- scheme compartilhado;
- Debug e Release separados;
- strict concurrency completo;
- warnings como errors no CI após baseline limpo;
- universal architectures conforme decisão M0.

Criar ainda um protótipo Release assinado com App Sandbox e somente
`com.apple.security.network.client`. Provar Keychain, UserNotifications,
`NSWorkspace`, export por `NSSavePanel` e `SMAppService`; qualquer impedimento
exige ADR antes de persistência pública.

#### M1-02 — cenas do app

- `BuildBeaconApp` com `MenuBarExtra` inicial;
- `Settings` scene;
- janela de onboarding identificada;
- janela de dashboard identificada;
- comportamento accessory/`LSUIElement` validado;
- comando Quit explícito;
- fechar janela não encerra o processo.

#### M1-03 — composição de dependências

- `AppEnvironment`/container no composition root;
- protocolos para relógio, credencial, preferências, API e notificações;
- implementações `unimplemented` falham cedo em debug;
- previews recebem fakes, não singletons globais.

#### M1-04 — localização e aparência

- String Catalog criado pelo integrador;
- sem strings de produto hardcoded;
- SF Symbols temporários com accessibility labels;
- light/dark, contraste e Reduce Motion verificados no shell.

### Testes e aceite

- unit target executa teste mínimo;
- UI test abre onboarding em estado não configurado;
- menu bar é inserido;
- app não aparece no Dock após onboarding/estado accessory definido;
- Settings e dashboard abrem uma única instância;
- build Debug e Release passam sem dependências externas.

**Gate M1:** `xcodebuild build`, `xcodebuild test` e `xcodebuild analyze` limpos.

## 9. M2 — domínio e políticas puras

### Objetivo

Fixar a semântica correta antes de conectar rede ou UI real.

### Ownership

- domain owner: `BuildBeacon/Domain/**` e `BuildBeaconTests/Domain/**`;
- integrador: inclusão de arquivos no projeto, se necessária.

### Tarefas

#### M2-01 — tipos fortes de identidade

Implementar e testar:

- `AccountID`;
- `WorkspaceID` e slug;
- `RepositoryID` e slug;
- `MonitorTarget` com `.repositoryLatest`, `.defaultBranch` e
  `.branch(exactName:)`;
- `MonitorID` incluindo conta/workspace UUID/repo UUID/target;
- `PipelineRunID`;
- `PipelineStepID`.

Branch explícita preserva case. Default acompanha a branch padrão atual sem
trocar `MonitorID`; repositoryLatest não equivale a default. Slugs são metadata,
não identidade. Testar rename de workspace/repo por UUID e troca de default.

#### M2-02 — modelos de pipeline

- `PipelineRun` com build, ref, commit, timestamps e phase;
- `PipelineStep` com phase própria;
- `PipelinePhase` incluindo queued, running, awaitingApproval, succeeded,
  failed, errored, expired, stopped e unknown com raw state/result;
- `MonitorObservation` com último run, tentativa, último sucesso e falha atual;
- `MonitoringSnapshot` e metadata do ciclo.

#### M2-03 — reducer de estado remoto

Criar uma política pura que só produza `succeeded` quando a API comunicar
sucesso explicitamente. Estados ausentes/novos produzem `unknown`.

Tabela mínima de testes:

- SUCCESSFUL;
- FAILED;
- ERROR;
- EXPIRED;
- STOPPED/CANCELLED;
- IN_PROGRESS;
- PENDING;
- PAUSED/HALTED;
- result ausente;
- state ausente;
- raw value novo;
- combinações inconsistentes.

#### M2-04 — agregador

- definir precedência formal;
- separar phase de quality/freshness;
- zero monitores → `notConfigured`, nunca healthy;
- unknown/offline/auth/rate limit → degraded/unavailable;
- falha parcial não é apagada por sucessos;
- duas branches do mesmo repo permanecem distintas.

#### M2-05 — diff e política de transição

- comparar snapshots por `MonitorID`;
- detectar add/remove/reorder sem falsos positivos;
- distinguir mudança de build sem mudança de phase;
- detectar failure→success, success→failure, running→success e
  any→awaitingApproval;
- primeiro baseline não notifica por padrão;
- representar dados anteriores durante refresh.

### Testes e aceite

- testes de tabela cobrem todos os estados conhecidos;
- property tests simples validam que nenhum unknown/unavailable resulta healthy;
- reorder não cria mudança semântica;
- mesmo repo em duas branches gera IDs e transições independentes;
- snapshot é `Sendable`, imutável e não contém token/DTO.

**Gate M2:** cobertura de decisão do reducer e agregador próxima de 100%; nenhuma
referência a SwiftUI, URLSession, Keychain ou DTO no Domain.

## 10. M3 — cliente Bitbucket e contratos HTTP

### Objetivo

Entregar uma camada HTTP tolerante, testável e atualizada para julho de 2026.

### Ownership

- API owner: `BuildBeacon/BitbucketAPI/**` e testes correspondentes;
- fixture owner: `BuildBeaconTests/Fixtures/Bitbucket/**`;
- integrador: configuração de network entitlement.

### Tarefas

#### M3-01 — transporte URLSession

- protocol `HTTPTransport`;
- implementação actor com `URLSession` reutilizável;
- configuração ephemeral com credential storage, URL cache e cookies
  explicitamente desabilitados;
- timeouts de request/recurso;
- ATS sem exceções;
- Accept/User-Agent;
- limite de body por header e cancelamento do streaming quando o teto real for
  ultrapassado;
- redirects autenticados cross-origin e downgrade HTTP rejeitados;
- cancelamento estruturado;
- mapeamento de `URLError` sem strings frágeis.

#### M3-02 — autenticação

- tipo opaco `APIToken` com descrição redigida;
- gerar Basic Auth somente no transporte;
- e-mail Atlassian + token;
- token nunca integra DTO, Domain, AppState ou log;
- header descartado após request;
- 401 e 403 diferenciados;
- capability validation por endpoints/scopes.

#### M3-03 — construção segura de endpoint

- `URLComponents` e `URLQueryItem`;
- percent-encoding de cada path component;
- nenhum `String(format:)` para URLs;
- HTTPS obrigatório;
- host allowlist;
- links de navegador construídos localmente por `LinkPolicy`;
- nenhuma URL de `next` ou payload pode exfiltrar Authorization.

#### M3-04 — DTOs privados e mappers

DTOs separados de Domain para:

- current user/workspace membership;
- metadata de project embutida em repository;
- repository;
- pipeline run/target/commit/state/result/stage;
- pipeline step/state/result;
- paginação.

Regras:

- campos potencialmente ausentes são opcionais;
- datas decodificadas por estratégia explícita;
- UUID raw preservado;
- campos extras ignorados;
- raw values novos preservados no mapper;
- nenhuma mensagem do servidor chega sem sanitização à UI.

#### M3-05 — paginação comum

- seguir `next` até `nil`;
- validar scheme, host e path antes de reenviar auth;
- detectar ciclos;
- deduplicar por ID estável;
- teto configurável de páginas/itens;
- cancelamento entre páginas;
- erro tipado e resultado parcial apenas por política do caso de uso.

#### M3-06 — endpoints de leitura

Implementar protocolos/casos de uso para:

- validar credencial/capacidades;
- listar workspaces;
- listar repos por workspace e derivar projetos da metadata; endpoint de
  projetos independente exige spike público antes de entrar;
- listar/refinar branches se necessário;
- obter execução mais recente por target;
- obter steps da execução.

Para branch, preferir filtro server-side documentado. Se precisar fallback,
paginar até encontrar com limite explícito e retornar “não encontrado dentro do
limite”, não “sem pipeline”.

#### M3-07 — taxonomia e retry

- 2xx esperado;
- 401 invalid credentials;
- 403 insufficient permissions;
- 404 resource disappeared;
- 409/422 action conflict se aplicável;
- 429 com `Retry-After` date/seconds quando presente e fallback quando ausente;
- 5xx transitório;
- timeout/offline/TLS/cancelled;
- decode/schema mismatch;
- request ID preservado quando disponível.

Retry:

- apenas idempotentes;
- exponencial com jitter;
- teto de tentativas e duração;
- respeito a `Retry-After` e observação de `X-RateLimit-NearLimit` sem presumir
  headers de remaining/reset;
- sem retry de 401/403/404/schema;
- cancelamento imediato.

### Fixtures obrigatórias

- response completa;
- response mínima válida;
- campos conhecidos ausentes;
- raw state/result desconhecido;
- data inválida;
- JSON inválido;
- página vazia com `next`;
- duas páginas e dedupe;
- ciclo de paginação;
- `next` com host malicioso;
- steps sequenciais e paralelos;
- pipeline pausada, expirada, stopped e sem result;
- branch que só aparece após múltiplas páginas.

### Aceite e testes

- todos os paths, query items, headers e methods são verificados via
  `URLProtocol` controlado;
- nenhuma suíte depende da rede pública;
- 429 determina próximo horário corretamente;
- redirect hostil não recebe Authorization e resposta oversized é cancelada;
- cancelamento interrompe paginação/retry;
- token não aparece em `String(describing:)`, logs ou falhas de teste;
- host malicioso em `next` é rejeitado antes do envio de auth;
- listas acima de 100 itens são completas.

**Gate M3:** contract tests verdes e revisão de segurança do transporte.

## 11. M4 — Keychain, preferências e conta

### Objetivo

Persistir segredo e configuração com transações previsíveis e recuperação.

### Ownership

- security owner: `Infrastructure/Credentials/**`;
- persistence owner: `Infrastructure/Persistence/**`;
- account application owner: `Application/Onboarding/**`;
- integrador: entitlements e resources.

### Tarefas

#### M4-01 — CredentialStore

- protocol async `save/read/update/delete`;
- Security.framework `SecItem*`;
- service com bundle ID;
- account com UUID remoto estável;
- `WhenUnlockedThisDeviceOnly` no 1.0; polling pausa no lock e retoma no unlock;
- `kSecAttrSynchronizable = false` e nenhum access group sem necessidade;
- update idempotente;
- logout apaga token;
- sem fallback para arquivo/UserDefaults;
- erros OSStatus mapeados sem vazar dados.

#### M4-02 — PreferencesStore

- actor serializa acesso;
- schema versionado;
- escrita atômica em Application Support;
- validação antes do commit;
- dedupe de monitores;
- backup recuperável em migração;
- corrupção não vira defaults silenciosos seguidos de overwrite;
- schema futuro entra em quarentena read-only e nunca é sobrescrito;
- arquivo versionado é fonte única de conta, monitores, intervalo e
  notificações; `UserDefaults` só guarda estado visual descartável.

#### M4-03 — transação de conexão

Ordem:

1. validar entrada em memória;
2. verificar API/capacidades;
3. salvar token no Keychain;
4. salvar metadata não secreta;
5. publicar estado conectado;
6. se uma etapa falhar, compensar/rollback de forma definida.

Troca de conta invalida seleções incompatíveis somente após confirmação.

#### M4-04 — logout e rotação

- revalidar sem expor token;
- substituir token via novo `SecureField`;
- orientar rotação/expiração sem apagar o token anterior antes do commit seguro
  do substituto;
- desconectar com confirmação;
- cancelar monitoramento antes de apagar;
- invalidar a generation antes de excluir qualquer dado;
- se apagar Keychain falhar, não declarar logout concluído;
- limpar conta, monitores, snapshots/backups e ledger/notificações da conta;
- manter preferência de launch at login separada da conta;
- limpar snapshots e notificações pendentes;
- preservar apenas preferências explicitamente escolhidas.

### Aceite e testes

- save/read/update/delete em serviço isolado de teste;
- integração Keychain usa service/account únicos por run e teardown garantido;
- segredo nunca chega a view model;
- falha ao salvar config após Keychain tem compensação testada;
- config corrompida exibe recuperação, não sobrescreve silenciosamente;
- logout deixa zero item Keychain do app;
- logs de todo o fluxo passam por teste de redaction.

**Gate M4:** revisão de threat model e inspeção manual do container do app.

## 12. M5 — onboarding e seleção de monitores

### Objetivo

Tornar primeira execução, recuperação e seleção claras para contas pequenas e
grandes.

### Ownership

- onboarding owner: `Features/Onboarding/**`;
- selection owner: `Features/MonitorSelection/**`;
- application owner: casos de uso associados;
- integrador: String Catalog.

### Tarefas

#### M5-01 — máquina de estado do onboarding

Estados:

- welcome;
- enteringCredential;
- validating;
- permissionReview;
- selectingMonitors;
- notificationChoice;
- completed;
- recoverable failure.

Eventos antigos são descartados por generation ID/cancelamento ao voltar ou
alterar credenciais.

#### M5-02 — conexão

- e-mail com validação leve, sem rejeitar formatos válidos raros;
- token em `SecureField`, nunca repopulado;
- link externo validado para criar token;
- progresso e cancelamento;
- mensagens distintas para 401, 403, offline, timeout, 429 e schema;
- informar scopes faltantes sem mostrar token.

#### M5-03 — seletor hierárquico

- workspace → projeto → repositório → target;
- busca;
- paginação completa e indicador de loading por nível;
- empty/error/retry próprios;
- cancelamento de request anterior ao trocar o pai;
- resposta antiga não substitui seleção atual;
- project-less repos continuam acessíveis;
- target default branch ou branch específica;
- seleção múltipla quando segura.

#### M5-04 — uma fonte de verdade

- configuração tem uma única coleção de monitores;
- pin/favorite é propriedade do monitor, não segunda lista órfã;
- remover oferece Undo antes de commit final quando viável;
- mutação falha reverte UI e informa erro;
- add/remove agenda refresh coalescido.

### Aceite e testes

- conta com mais de 100 repos encontra todos os itens fixture;
- troca rápida de workspace não mostra resposta obsoleta;
- repo pode ser monitorado em duas branches;
- projetos homônimos não colidem;
- lista vazia e erro têm ação clara;
- VoiceOver e teclado concluem todo onboarding;
- fechar e reabrir preserva progresso apenas quando seguro;
- screenshot tests, se adotados, não substituem semantic/UI tests.

**Gate M5:** primeira execução completa em conta fixture e teste exploratório com
conta real não produtiva.

## 13. M6 — motor de monitoramento

### Objetivo

Executar atualizações corretas e eficientes sob concorrência, suspensão e falha.

### Ownership

- monitoring owner: `Application/Monitoring/**` e testes;
- API owner: otimizações/caches internos dentro de `BitbucketAPI/**`;
- integrador: lifecycle wiring em `App/**`.

### Tarefas

#### M6-01 — MonitoringEngine actor

- uma Task raiz possuída e cancelável; nenhum `Task.detached` ou fire-and-forget;
- máquina explícita idle/running/pending/backingOff/pausedAuth/stopped;
- um ciclo lógico em voo, com filhos estruturados sempre aguardados;
- `requestRefresh(reason:)` coalescente;
- cycle ID, config revision, account generation e guard antes de commit/notificar;
- cancelar em logout/troca de conta/shutdown;
- publicar eventos tipados;
- nenhuma mutação de UI fora do MainActor;
- snapshot parcial preservado.

#### M6-02 — scheduler

- `Clock` injetável;
- deadline calculado após conclusão;
- tolerância para eficiência energética;
- intervalo mínimo/máximo validado em Domain;
- mudança de intervalo reprograma uma vez;
- manual refresh não destrói cadência;
- wake do sistema agenda ciclo com jitter;
- lock pausa acesso ao token/polling; unlock agenda retomada coalescida;
- sleep/cancelamento testáveis sem esperar tempo real.

#### M6-03 — concorrência limitada

- task group com limite inicial de quatro monitores;
- não criar N requests sem limite;
- fairness entre projetos;
- cada monitor mantém seu erro;
- cache por ciclo evita buscar latest/steps repetidamente;
- steps só são consultados quando necessários.

#### M6-04 — backoff e rate limit

- backoff exponencial com jitter;
- `Retry-After` prevalece;
- gate compartilhado impede que refresh manual fure rate limit;
- `X-RateLimit-NearLimit` pode reduzir pressão proativamente;
- 401/403 pausam scheduler e pedem intervenção;
- 429 global versus por endpoint tratado conforme evidência;
- sucesso zera backoff apropriado;
- UI recebe `nextRefresh` real.

#### M6-05 — frescor

- `lastAttempt`, `lastSuccess`, `observedAt` e `nextRefresh` distintos;
- stale threshold derivado do intervalo com piso/teto;
- falha de rede mantém último resultado como stale, não healthy fresh;
- relógio de parede só para exibição; clock monotônico para scheduler.

### Matriz de testes do scheduler

| Caso | Evidência esperada |
|---|---|
| ciclo normal | espera intervalo após conclusão |
| refresh durante ciclo | nenhum segundo ciclo simultâneo; um follow-up no máximo |
| dez cliques | coalescidos |
| troca de intervalo | deadline recalculado sem busy loop |
| logout | request e sleep cancelados |
| resposta antiga | rejeitada pelo generation guard |
| 429 | dorme até Retry-After |
| 5xx repetido | backoff cresce com teto |
| 401 | polling pausa |
| wake | um refresh com jitter |
| parcial | successes e failures coexistem no snapshot |
| 100 monitores | concorrência nunca supera limite |

**Gate M6:** TestClock prova ausência de busy loop e sobreposição; teste de
performance confirma limite de concorrência.

## 14. M7 — menu bar, dashboard e detalhes

### Objetivo

Apresentar o mesmo snapshot coerente em todas as superfícies nativas.

### Ownership

- menu owner: `Features/MenuBar/**`;
- dashboard owner: `Features/Dashboard/**`;
- detail owner: `Features/PipelineDetail/**`;
- app state owner: `Application/State/**`;
- integrador: assets/SF Symbols/localização.

### Tarefas

#### M7-00 — matriz de estados por superfície

Para menu, onboarding, selector, dashboard, detail e settings, documentar
conteúdo, símbolo/texto, ação primária/secundária, controles habilitados,
preservação do snapshot anterior e anúncio VoiceOver em never loaded, loading,
refreshing, empty, partial, stale, offline, auth, permission, rate limit e
schema error.

#### M7-01 — AppModel no MainActor

- observa eventos do MonitoringEngine;
- publica snapshot e metadata;
- mantém dados anteriores durante refresh;
- não contém token nem chama URLSession;
- geração antiga não modifica UI;
- deep links internos usam IDs, não URLs arbitrárias.

#### M7-02 — status item

Antes da implementação avançada, comparar `MenuBarExtra` styles com
`NSStatusItem`/`NSMenu` usando lista agrupada, atualização de label, foco,
VoiceOver, claro/escuro e 50 monitores. Limitação essencial gera ADR de fallback
antes que outras features dependam da escolha.

Requisitos:

- SF Symbol/template apropriado;
- símbolo, texto e accessibility value, não cor isolada;
- tooltip/resumo atualizado em todo snapshot relevante;
- stable IDs por monitor;
- remover último monitor limpa conteúdo antigo;
- menu abre instantaneamente com cache em memória;
- “Atualizar agora” informa progresso/conclusão;
- atalhos e ações nativas.

O menu prioriza attention e running, mostra no máximo 12 monitores e encaminha
o restante para “Mostrar todos no painel”, preservando ordem enquanto aberto.

#### M7-03 — dashboard

- toolbar com refresh, busca/filtro e frescor;
- agrupamento por workspace/projeto usando IDs;
- lista/tabela de monitores;
- status textual e símbolo;
- branch, build, commit, duração e last success;
- estados empty/loading/refreshing/partial/stale/offline/auth/rate limit/schema;
- preservar posição/tamanho de janela do usuário;
- não recentralizar/redimensionar a cada update.

#### M7-04 — detalhe

- cabeçalho de execução;
- steps em lista/flow nativo;
- representar paralelo/dependência somente se API comprovar;
- falha em steps não remove o monitor;
- no runs e no steps são estados próprios;
- links para pipeline/commit/step passam por `LinkPolicy`;
- contexto e menus por teclado/VoiceOver.

#### M7-05 — links seguros

- construir URLs canônicas localmente;
- somente `https`;
- hosts permitidos explícitos;
- percent-encoding;
- confirmar links fora da allowlist ou rejeitá-los;
- abrir via `NSWorkspace`;
- nenhum body/URL arbitrário vindo da UI.

### Aceite e testes

- mudança de build saudável atualiza link mesmo sem mudança de phase;
- mudança de nome/stage/reason/frescor atualiza menu;
- reorder não troca ações entre itens;
- remover tudo apaga menu/snapshot anterior;
- same repo/different branch abre contexto correto;
- erro parcial permanece visível;
- estados são consistentes em menu, dashboard e detalhe;
- UI test cobre Settings/Dashboard/open/close e atalhos;
- auditoria VoiceOver, Increase Contrast, Differentiate Without Color e Reduce
  Motion.

**Gate M7:** nenhuma superfície mostra healthy para unknown/unavailable/stale.

## 15. M8 — notificações e ações manuais

### Objetivo

Informar mudanças reais sem spam e decidir com evidência se o app pode executar
uma aprovação remota.

### Ownership

- notification owner: `Infrastructure/Notifications/**` e política em Domain;
- action spike owner: `BitbucketAPI/Endpoints/**` isolado por feature flag;
- UI owner: confirmações e feedback;
- integrador: categories, identifiers e signing config.

### Tarefas

#### M8-01 — autorização contextual

- explicar benefício antes do prompt do sistema;
- solicitar ao concluir onboarding ou habilitar setting;
- tratar denied/provisional/authorized;
- oferecer link para System Settings quando negado;
- app funciona plenamente sem notificações.

#### M8-02 — NotificationPolicy

- baseline inicial silencioso;
- failure edge;
- recovery edge;
- awaiting approval opcional;
- auth invalid uma vez por período;
- outage prolongado com cooldown;
- dedupe por account + monitor + run + transition;
- novo run falho pode notificar uma vez mesmo se a phase anterior também era
  failed; failure→unknown nunca é recovery;
- persistir ledger sanitizado e atômico para deduplicação após restart, com
  retenção limitada e limpeza ao remover monitor/logout;
- nunca incluir token ou metadata excessiva.

#### M8-03 — entrega e deep link

- `UNUserNotificationCenter`;
- category/action IDs estáveis;
- userInfo com IDs internos;
- abrir dashboard/detalhe correto;
- rotear o mesmo ID interno em app ativo e cold launch;
- falha de entrega registrada localmente sem quebrar monitoramento;
- notificações pendentes canceladas ao logout/remover monitor.

#### M8-04 — spike de ação manual

Antes de implementar:

- provar endpoint em documentação pública ou suporte oficial;
- provar método, body, status e idempotência;
- provar scope mínimo;
- testar conflitos/double-click/execução já retomada;
- decidir se a ação é aprovação, trigger ou somente link externo.

Se a prova falhar, o 1.0 abre a página correta no navegador. Não usar endpoint
privado ou inferido.

Se aprovada:

- feature flag inicialmente off;
- scope de escrita opt-in;
- confirmação mostra workspace/repo/branch/build/step;
- botão desabilita durante request;
- timeout não presume sucesso;
- refresh posterior confirma o resultado;
- nenhum retry automático de POST sem chave/idempotência comprovada.

### Aceite e testes

- exatamente uma notificação por transição;
- relaunch não duplica alerta quando baseline persistido;
- duas branches não colidem;
- falha→unknown não vira “recovered”;
- denied não gera loop de prompts;
- deep link não aceita URL externa arbitrária;
- ação manual tem contract test ou permanece fora do release.

**Gate M8:** revisão de produto e segurança aprova política de ruído e scope.

## 16. M9 — settings, login item, acessibilidade e eficiência

### Objetivo

Fechar os fluxos de operação diária e preparar beta de qualidade macOS.

### Ownership

- settings owner: `Features/Settings/**`;
- infra owners: LoginItem/Logging;
- integrador: localization, entitlements e QA matrix.

### Tarefas

#### M9-01 — Settings nativos

Tabs/seções:

- Account: status, revalidar, substituir token, desconectar;
- Monitoring: add/remove/reorder/pin;
- Refresh: picker de valores suportados, não campo numérico livre;
- Notifications: tipos e autorização;
- General: launch at login, appearance quando necessário;
- Diagnostics: última tentativa/sucesso/erro e export sanitizado.

#### M9-02 — launch at login

- `SMAppService.mainApp`;
- `SMAppService.status` como fonte de verdade refletida na UI;
- erro acionável;
- teste manual após reboot/login;
- desligar não deixa helper órfão.

#### M9-03 — logging e diagnóstico

- categorias `Logger`;
- cycle ID/request ID;
- campos privados por padrão;
- redaction test de token/Auth;
- export sem repo/e-mail por padrão;
- opção explícita para incluir metadata sensível;
- tamanho/retenção limitados pelo sistema.

#### M9-04 — acessibilidade

- VoiceOver end-to-end;
- teclado: Command-R, Command-comma, Command-F, Return e Escape;
- foco após add/remove/erro;
- labels/value/hints;
- tamanho mínimo de targets;
- contraste e cor não exclusiva;
- Reduce Motion;
- datas relativas com valor completo acessível;
- idioma e pluralização revisados.

#### M9-05 — performance/energia

- Instruments Time Profiler;
- Allocations e Leaks;
- Energy Log ocioso e em refresh;
- medir wakeups;
- 20 e 100 monitores fixture;
- memória ociosa e após 24h;
- ausência de timers duplicados;
- abrir menu < 150 ms com snapshot em memória.

**Gate M9:** checklist de acessibilidade e performance assinado; zero P0/P1 aberto.

## 17. M10 — CI, assinatura, notarização e release

### Objetivo

Entregar um binário instalável e confiável em Mac limpo.

### Ownership

- integrador/release owner exclusivo: workflow, certificados, Git, tags,
  archive, assinatura e publicação;
- demais owners: correções em seus paths, reencaminhadas após falhas.

### Tarefas

#### M10-01 — CI de pull request

- selecionar Xcode fixo suportado;
- build Debug;
- unit/integration tests sem rede;
- UI smoke tests quando estáveis;
- analyze;
- strict concurrency/warnings;
- secret scanning;
- artifacts de test result;
- cancelar runs obsoletos da mesma branch.

#### M10-02 — CI de release

- archive Release universal;
- assinatura Developer ID;
- Hardened Runtime;
- entitlements mínimos;
- inventário/SBOM de toolchain, actions, scripts e pacotes, mesmo sem packages de
  runtime;
- notarization via credencial segura do CI;
- stapling;
- DMG assinado;
- checksum SHA-256;
- provenance/SBOM simples das dependências — idealmente apenas frameworks do
  sistema;
- secrets nunca impressos.

#### M10-03 — validações do artefato

```bash
codesign --verify --deep --strict --verbose=2 BuildBeacon.app
spctl --assess --type execute --verbose=4 BuildBeacon.app
xcrun stapler validate BuildBeacon.app
```

Também:

- instalar DMG em conta de usuário limpa;
- executar sem Xcode/certificado local;
- testar Keychain prompt/comportamento;
- testar light/dark, offline e token inválido;
- testar arm64 e Intel conforme suporte;
- confirmar ausência de Dock icon;
- confirmar logout/delete de token;
- revisar Info.plist, entitlements e privacy disclosure.

#### M10-04 — beta

- grupo reduzido;
- feedback estruturado sobre ruído, estados e onboarding;
- diagnóstico opt-in;
- nenhuma telemetria silenciosa;
- critérios de rollback;
- changelog próprio e documentação de instalação.

#### M10-05 — release 1.0

- versão única em todos os metadados;
- tag assinada se infraestrutura permitir;
- release notes próprias;
- checksum publicado;
- notarization stapled validada;
- issues P0/P1 fechadas;
- known issues honestas;
- plano de resposta a revogação/comprometimento de certificado.

**Gate M10:** instalação e uso completo em Mac limpo, sem bypass do Gatekeeper.

## 18. Estratégia de testes consolidada

### 18.1 Pirâmide

- muitos testes puros de Domain/Application;
- contract tests do transporte com `URLProtocol`;
- integração local para Keychain/persistência/notificações abstraídas;
- poucos UI tests focados nos caminhos críticos;
- testes manuais apenas onde APIs do sistema não forem determinísticas.

### 18.2 Matriz por risco

| Risco | Teste obrigatório |
|---|---|
| falso verde | reducer/agregador exaustivo |
| token exposto | redaction + arquitetura + inspeção de persistência |
| busy loop | TestClock mede sleeps/deadlines |
| refresh sobreposto | stress/coalescing/generation guard |
| branch colidida | duas branches, mesmo repo, transições diferentes |
| paginação truncada | 2+ páginas, >100 itens, cycle/cap |
| auth enviada a host externo | malicious `next` host |
| menu/link stale | novo build, mesma phase, URL diferente |
| config perdida | corrupção, migração, falha durante write |
| notificação duplicada | baseline/relaunch/reorder |
| ação duplicada | double-click/timeout/conflict |
| API mudou | unknown fields/raw states/missing optional fields |

### 18.3 Test doubles necessários

- `TestClock`;
- `StubBitbucketAPI` roteado por endpoint;
- `ControlledHTTPTransport`;
- `InMemoryCredentialStore` que nunca imprime segredo;
- `InMemoryPreferencesStore` com fault injection;
- `NotificationRecorder`;
- `LinkOpenerSpy`;
- `LifecycleEventSource`;
- UUID/date factories determinísticas.

### 18.4 Testes proibidos como única evidência

- teste que depende da API pública ao vivo;
- `sleep` real para scheduler;
- snapshot visual como única prova de acessibilidade;
- teste que usa token pessoal;
- teste feliz sem 401/403/429/offline/schema;
- validação manual sem registro para gate de release.

## 19. Comandos de validação previstos

Os nomes finais dependem do projeto criado em M1:

```bash
xcodebuild \
  -project BuildBeacon.xcodeproj \
  -scheme BuildBeacon \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project BuildBeacon.xcodeproj \
  -scheme BuildBeacon \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project BuildBeacon.xcodeproj \
  -scheme BuildBeacon \
  -destination 'platform=macOS' \
  analyze
```

Cada frente roda primeiro sua suíte específica; o integrador roda a suíte
completa após integração e revisa o diff consolidado.

## 20. Plano de paralelismo por ondas

### Onda A — fundação

- integrador: projeto/entitlements/resources;
- domain owner: tipos e policies, após contratos estabilizados;
- app shell owner: composition root e scenes em paths disjuntos;
- test support owner: doubles/fixtures base.

### Onda B — infraestrutura

- API owner: transport/DTO/endpoints;
- security owner: Keychain;
- persistence owner: config/migrations;
- domain owner: reducer/diff.

Hotspots continuam no integrador.

### Onda C — aplicação e UX

- monitoring owner: engine/scheduler;
- onboarding owner;
- selection owner;
- menu/dashboard owner em paths separados.

Antes da onda, estabilizar `AppEvent`, `MonitoringSnapshot`, `AppError` e os
protocolos públicos.

### Onda D — hardening

- accessibility/UX audit;
- API/security audit;
- performance/energy audit;
- CI/distribution pelo integrador.

Correções retornam ao owner original; revisores não editam o mesmo path.

## 21. Backlog priorizado

### P0 — bloqueia qualquer release

- API Token atual e Keychain;
- sem segredo em UI/log/arquivo;
- reducer sem falso healthy;
- identidade inclui branch;
- paginação completa;
- scheduler sem busy loop;
- single-flight e cancellation;
- 401/403/429/offline/schema distintos;
- snapshot/diff semântico;
- onboarding recuperável;
- menu e dashboard consistentes;
- assinatura/notarização;
- unit/contract/scheduler tests.

### P1 — necessário para 1.0 de qualidade

- seleção de branch;
- partial/stale UX;
- notifications failure/recovery;
- settings completos;
- launch at login;
- VoiceOver/keyboard/contrast;
- link policy;
- diagnostics sanitizado;
- Energy Log e soak test;
- universal binary conforme ADR.

### P2 — pode seguir após 1.0

- ação manual, se endpoint público comprovado;
- filtros e favoritos avançados;
- histórico local maior;
- OAuth seguro;
- atualização automática com design de supply chain;
- múltiplas contas;
- outros providers;
- widgets/App Intents.

## 22. Registro de riscos operacional

| ID | Risco | Sinal antecipado | Owner | Resposta |
|---|---|---|---|---|
| R-01 | mudança Bitbucket | contract fixture/API changelog | API | adapter + release rápido |
| R-02 | rate limit | 429/latência crescente | Monitoring | backoff/limite/cache |
| R-03 | leak de segredo | log/header/config | Security | bloquear release e rotacionar |
| R-04 | falso healthy | unknown verde | Domain | invariant test P0 |
| R-05 | notification spam | alerta repetido | Product | dedupe/cooldown |
| R-06 | scheduler quente | wakeups/CPU | Monitoring | TestClock/Instruments |
| R-07 | ação perigosa | duplicate trigger | API/Product | feature off/link externo |
| R-08 | config corrompida | decode failure | Persistence | backup/recovery |
| R-09 | Gatekeeper | spctl/notary falha | Release | parar publicação |
| R-10 | escopo cresce | milestones sem gate | Integrator | manter non-goals |

## 23. Checklist de segurança por PR

- [ ] O diff toca segredo, auth, URL ou persistência?
- [ ] Algum valor sensível chega a UI, log, erro ou fixture?
- [ ] Authorization só é enviado a host permitido?
- [ ] URL usa componentes e percent-encoding?
- [ ] Endpoint mutável tem confirmação/idempotência?
- [ ] Cancellation e timeout estão definidos?
- [ ] Erro desconhecido degrada com segurança?
- [ ] Mudança de schema mantém compatibilidade?
- [ ] Testes incluem caminhos adversos?
- [ ] Entitlement novo tem justificativa mínima?
- [ ] Dependência nova é realmente necessária e revisada?

## 24. Checklist de UX/acessibilidade por feature

- [ ] never loaded, loading, refreshing, empty e success;
- [ ] partial, stale, offline, auth, permission, rate limit e schema error;
- [ ] texto + símbolo, não cor isolada;
- [ ] VoiceOver label/value/hint;
- [ ] teclado e ordem de foco;
- [ ] Reduce Motion e Increase Contrast;
- [ ] strings localizáveis e pluralização;
- [ ] datas/durações por FormatStyle;
- [ ] erro tem recuperação;
- [ ] mutação falha restaura estado;
- [ ] janela respeita tamanho/posição do usuário;
- [ ] ação externa deixa claro o destino.

## 25. Checklist de release

- [ ] todos os gates M0–M10 aprovados;
- [ ] zero P0/P1 aberto sem waiver explícito;
- [ ] testes completos e analyze verdes;
- [ ] Instruments sem regressão crítica;
- [ ] VoiceOver/keyboard/contrast revisados;
- [ ] token ausente de logs/config/artifacts;
- [ ] entitlements mínimos revisados;
- [ ] archive Release reproduzível;
- [ ] codesign verificado;
- [ ] notarização aceita e stapled;
- [ ] `spctl` aceita o app;
- [ ] DMG e checksum verificados;
- [ ] instalação em Mac limpo;
- [ ] logout remove Keychain;
- [ ] offline/401/403/429 testados;
- [ ] notas e política de privacidade próprias;
- [ ] plano de rollback e resposta a incidente conhecido.

## 26. Sequência recomendada imediata

1. decidir as oito perguntas abertas do `discussion.md`;
2. executar o spike M0-03 de API/scopes/branch/ação manual;
3. registrar ADR-001 a ADR-010;
4. criar o projeto Xcode em M1;
5. implementar M2 test-first antes de qualquer UI rica;
6. implementar M3/M4 em paralelo com contratos já congelados;
7. integrar onboarding, scheduler e superfícies apenas após os gates de domínio,
   API e Keychain;
8. introduzir assinatura/notarização cedo, não no último dia;
9. manter ação manual fora do release enquanto o contrato público não estiver
   comprovado;
10. revisar este plano a cada milestone sem apagar decisões históricas.

## 27. Condição objetiva de encerramento

O projeto está pronto para 1.0 somente quando o produto é correto sob falha, não
apenas no caminho feliz. Em particular:

- unknown, offline, auth error e stale nunca aparecem healthy;
- o token existe apenas no Keychain e no instante mínimo de montagem da request;
- nenhuma combinação de timer e clique cria requests simultâneas do mesmo ciclo;
- contas paginadas e múltiplas branches funcionam;
- menu, dashboard, detalhe e notificações derivam do mesmo snapshot;
- acessibilidade e eficiência são evidências de gate;
- o binário é assinado, notarizado e aceito pelo Gatekeeper.

Qualquer release que viole uma dessas condições deve ser bloqueado.

## 28. Ledger de execução e governança

### 28.1 Status por milestone

| Milestone | Estado em 21/07/2026 | Evidência / limite |
|---|---|---|
| M0 | concluído para fundação | decisões registradas, clean-room e contratos oficiais verificados; Git não foi inicializado sem solicitação |
| M1 | concluído para candidato local | Swift 6/macOS 14, scenes, sandbox, resources, Debug/Release e universal; sem projeto Xcode/target XCUITest dedicado |
| M2 | concluído | tipos fortes, reducer único, agregação, freshness, snapshot, diff e invariantes testados |
| M3 | concluído | API token, endpoints de leitura, paginação, filtro de branch, steps, retry, streaming limitado e redirects seguros |
| M4 | concluído | Keychain, configuração versionada/atômica, rollback de conexão, corrupção/quarentena e logout consistente |
| M5 | funcional, gate amplo parcial | conexão e seleção workspace→repo→target entregues; onboarding multipasso, busca e Undo permanecem melhoria de UX |
| M6 | concluído | actor single-flight, coalescência, generation guard, TestClock, concorrência limitada, backoff e rate limit |
| M7 | funcional, gate manual parcial | menu, dashboard, detalhe, busca/filtro, links e stale explícito; falta auditoria VoiceOver/XCUITest completa |
| M8 | funcional, deep link parcial | transições, ledger, entrega e limpeza implementados; clique/cold-launch routing ainda não é gate aprovado |
| M9 | funcional, hardening parcial | Settings, login item, logging/redaction; faltam diagnóstico exportável, Instruments e QA de reboot |
| M10 | Preview empacotável; produção bloqueada | universal, sandbox, Hardened Runtime, assinatura ad hoc/local, DMG + checksum; sem Developer ID/notary/CI/Mac limpo |

“Parcial” não autoriza publicação. O candidato local é utilizável, mas beta/1.0
públicos continuam bloqueados pelos itens explicitamente abertos.

### 28.2 Gates executados

| Gate | Resultado |
|---|---|
| `swift test` | 89 executados, 0 falhas, 1 integração Keychain opt-in ignorada no gate padrão |
| integração Keychain opt-in | 1 executado, 0 falhas; save/read/update/delete com teardown |
| build Release universal | `arm64` e `x86_64` produzidos pelo toolchain Apple |
| `codesign --verify --deep --strict` | aprovado para assinatura local |
| `plutil -lint` | aprovado |
| App Sandbox | ativo |
| entitlements | somente sandbox e cliente de rede |
| Hardened Runtime | ativo |
| LaunchServices/processo | bundle registrado e processo do menu bar ativo |
| referência/segredo scan | nenhum nome/crédito/URL proibido; nenhuma credencial real encontrada |

### 28.3 Bugs de auditoria fechados

- `BitbucketAPIError` agora fornece `ObservationFailure` ao motor;
- 401 pausa polling; 429 e falhas transitórias aplicam backoff 30–900 s;
- `Retry-After` do servidor prevalece sem truncamento;
- transporte cancela streaming ao exceder o body cap;
- redirects exigem HTTPS, host, porta efetiva e root `/2.0` esperados;
- mapper usa o reducer central, incluindo `HALTED`, cancelamento e resultados
  conhecidos;
- autenticação gera um evento por conta/transição, não um por monitor;
- falha inicial de configuração tenta novamente sem busy loop;
- ledger restaura memória quando persistência falha;
- logout/troca suspendem snapshots antigos e limpam notificações dos monitores;
- seleção assíncrona rejeita resposta do pai obsoleto;
- add/remove são serializados e preferências fazem rollback visual;
- stale/unavailable nunca reutilizam apresentação verde da última pipeline.

### 28.4 Itens obrigatórios antes de distribuição pública

1. obter Apple Developer Team e certificado `Developer ID Application`;
2. assinar com secure timestamp, notarizar e staplear;
3. exigir `spctl --assess` e `stapler validate` verdes;
4. gerar DMG assinado, SHA-256, SBOM/provenance e release notes;
5. criar CI com Xcode fixo, build/test/analyze e secret scanning;
6. executar XCUITest hospedado, VoiceOver/teclado/contraste e routing de
   notificações em cold launch;
7. executar Instruments, soak/energia e teste Intel real;
8. validar instalação, Keychain, login item e logout em Mac/usuário limpo;
9. completar localização pt-BR ou declarar inglês como único idioma do 1.0;
10. fechar diagnóstico exportável e metadados/ícone finais.

### 28.5 Comandos canônicos atuais

```bash
swift test
BUILD_BEACON_KEYCHAIN_INTEGRATION=1 swift test \
  --filter InfrastructureServicesTests/testKeychainCredentialLifecycleWhenIntegrationIsEnabled
swift build -c release --arch arm64 --arch x86_64
./scripts/build_app.sh
./scripts/install_app.sh
lipo -archs '/Applications/Build Beacon.app/Contents/MacOS/BuildBeacon'
codesign --verify --deep --strict --verbose=2 '/Applications/Build Beacon.app'
```

O script de instalação sempre reconstrói, copia para staging, verifica a
assinatura e só então substitui atomicamente a versão anterior com rollback em
caso de falha.

### 28.6 Incremento governado — onboarding de token

Entregue após feedback de primeira execução:

- URL oficial fixa `https://id.atlassian.com/manage-profile/security/api-tokens`;
- permissões `User data`, `Workspaces`, `Repositories` e `Pipelines`, todas
  somente leitura;
- botões para copiar cada ID exato e ação geral que copia somente os quatro IDs;
- `PasteButton` nativo e explícito, sem inspeção automática do clipboard;
- retorno do navegador direciona foco ao `SecureField`;
- símbolo nativo de farol luminoso no lugar da metáfora visual anterior;
- strings em inglês e pt-BR para todo o novo fluxo;
- sete testes de contrato para URLs, allowlists de permissões/IDs e ausência de
  material sensível no texto copiável.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

Correção posterior da primeira execução: erros que conformam
`ObservationFailureProviding` são convertidos no boundary do `AppModel`; a UI
não apresenta mais nomes internos ou códigos como `error 6`. Credencial inválida,
permissão insuficiente e HTTP 5xx possuem regressões automatizadas e mensagens
acionáveis. Os cards do onboarding ocupam a largura integral e erros longos
quebram linha sem clipping.

Endurecimento posterior do fluxo escopado: o passo de criação agora instrui
explicitamente **Create API token with scopes** em vez do token genérico,
solicita apenas o aplicativo Bitbucket, liga para o guia oficial e mantém a
allowlist dos quatro escopos Read. Mensagens de credencial/permissão apontam
para esse mesmo fluxo sem expor códigos internos.

### 28.7 Incremento governado — identidade visual unificada

- `BuildBeaconBrand.symbolName` centraliza `light.beacon.max.fill`;
- onboarding, cabeçalho do menu e `MenuBarExtra` consomem o mesmo contrato;
- a barra mantém a silhueta fixa e sobrepõe somente um badge de estado;
- o cabeçalho interno mantém o farol na cor de destaque e comunica estado no
  texto adjacente;
- o título do estado agregado permanece disponível ao VoiceOver;
- regressão automatizada valida o símbolo nativo e proíbe antena na identidade.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.8 Incremento governado — busca exata de escopos

- allowlist canônica preserva, em ordem, `read:user:bitbucket`,
  `read:workspace:bitbucket`, `read:repository:bitbucket` e
  `read:pipeline:bitbucket`;
- cada linha associa descrição humana ao ID técnico monoespaçado e selecionável;
- cópia individual escreve somente um ID pesquisável no clipboard;
- cópia geral escreve somente os quatro IDs separados por `\n`;
- strings de interface estão completas em inglês e pt-BR; IDs não são
  traduzidos;
- Write/Admin e material de credencial permanecem proibidos por regressão.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.9 Incremento governado — schema de workspaces

- `GET /user` continua responsável por validar e identificar a conta;
- `GET /user/workspaces` decodifica `values[].workspace` do schema oficial
  `workspace_access`;
- o formato direto anterior permanece aceito como fallback de leitura;
- paginação e deduplicação usam o UUID do workspace interno;
- registros sem workspace, UUID ou slug falham de forma explícita;
- fixtures cobrem formato oficial, legado e payload incompleto;
- Settings renderiza `errorMessage` somente no banner global com Dismiss.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.10 Incremento governado — startup resiliente

- `AppModel.startIfNeeded()` possui a task global de inicialização;
- views transitórias apenas solicitam o startup e não controlam seu lifetime;
- chamadas concorrentes são coalescidas;
- cancelamento do chamador não cancela configuração/workspaces;
- falha de descoberta permite retry sem duplicar monitoring ou reload;
- três regressões determinísticas usam continuations, sem sleeps reais.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.11 Incremento governado — publicação Preview

- SVG original transparente validado em render 512 × 512 com canal alpha;
- README público contém hero, badges, CTAs, dois diagramas Mermaid, segurança,
  instalação, uso, build, testes, troubleshooting e limitações;
- `SECURITY.md`, `CONTRIBUTING.md`, licença MIT e `.gitignore` entregues;
- build público usa assinatura ad hoc por padrão e aceita override explícito;
- `package_dmg.sh` verifica app universal, gera DMG UDZO e checksum por basename;
- `.build`, `dist`, chaves, certificados, ambientes e artefatos não são
  versionados.

O gate Apple de produção continua aberto até Developer ID, notarização,
stapling, CI de release e validação em Mac limpo.

### 28.12 Incremento governado — seleção em massa

- sheet nativa com projetos, `No Project`, busca e ordenação estável;
- seleção múltipla preservada entre filtros, Select All Visible e Clear;
- alvo comum Latest run ou Default branch e duplicata exata bloqueada;
- `addMonitors(repositories:target:)` persiste o lote atomicamente;
- entradas duplicadas, outro workspace e alvos existentes são ignorados;
- falha de persistência não altera a configuração visível;
- branch específica permanece no modo Advanced;
- strings equivalentes em inglês e pt-BR.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.13 Incremento governado — toolbar e empty run

- refresh usa um único toolbar item com geometria fixa e sem layout shift;
- spinner é oculto da árvore a11y duplicada; botão anuncia o estado;
- busca do dashboard inclui nome do projeto;
- observação fresca sem run mostra `No Pipeline Run` com símbolo de tray;
- estado remoto desconhecido continua `Unknown` com question mark;
- falha sem run mantém precedência e símbolo de indisponibilidade;
- três regressões cobrem a separação semântica.

Gate do incremento: suíte total com 89 testes, 0 falhas e 1 integração Keychain
opt-in omitida no gate padrão.

### 28.14 Incremento governado — operação contínua e contexto completo

Entregue:

- startup always-on independente de views, com wake, ativação e recuperação de
  rede coalescidos pelo engine;
- polling adaptativo por monitor, backoff transitório individual e rate limit
  global não contornável;
- indicador de última atualização/próximo ciclo e refresh imediato quando
  aplicável;
- permissão de notificação contextual no primeiro monitor, status real, teste,
  categoria registrada e rota acionável para monitor/run/build;
- abertura garantida do dashboard a partir de notificação e callout para build
  original quando a execução corrente já mudou;
- contexto de commit e PR opcional somente leitura, com cache limitado e isolado
  por conta e links revalidados por allowlist;
- filtros de status/projeto, busca, agrupamento, favoritos, ordenação e hide
  no-run com seleção consistente e acessibilidade;
- menu bar com contagens sem falso verde e disponibilidade separada de falha de
  pipeline;
- histórico sanitizado e limitado, UI de timeline, seleção/limpeza explícita e
  stores locais com escrita atômica e permissões 0700/0600;
- schema de configuração v2 com migração v0/v1, decode estrito do schema atual,
  backup, quarentena e proteção contra schema futuro;
- localização en/pt-BR para textos literais e formatos dinâmicos;
- README, SECURITY e CONTRIBUTING alinhados ao contrato read-only e local-first.

Validações consolidadas:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 156 executados, 0 falhas, 1 Keychain opt-in omitido |
| `swift build -c release` / target UI e Kit | aprovado |
| `plutil -lint` en/pt-BR | aprovado |
| `git diff --check` | aprovado |
| scan de paths/segredos/referência | aprovado |
| API e links | somente leitura; PR opcional; host HTTPS allowlisted |
| persistência | config/ledger/history atômicos e privados |

O gate de distribuição Apple de produção continua separado: Developer ID,
notarização, stapling, CI de release e validação em máquina limpa permanecem
requisitos antes de remover o rótulo Preview.

### 28.15 Incremento governado — linhas uniformes do dashboard

- altura normal mínima centralizada em 64 pontos;
- insets verticais implícitos da `List` removidos;
- textos remotos limitados a uma linha com truncamento previsível;
- coluna de build mantém largura intrínseca sem expandir a célula;
- fontes ampliadas podem crescer além do mínimo, preservando acessibilidade;
- regressão dedicada protege a métrica compartilhada.

Gate do incremento: suíte total com 142 testes, 0 falhas e 1 integração
Keychain opt-in omitida no gate padrão; build release aprovado.

### 28.16 Incremento governado — inicialização e refresh público

Entregue nesta atualização de governança:

- `/init` reconhece `AGENTS.md` como guia público de contribuição e execução,
  preservando discussion e planning como fontes das decisões e do ledger;
- README foi alinhado às capacidades entregues: quatro escopos obrigatórios
  somente leitura, enriquecimento de PR opcional, polling automático e faixa
  configurável de 30 s a 15 min;
- README inclui a seleção em lote orientada a projeto e o ritmo estável das
  linhas do dashboard, sem prometer webhook, escrita remota ou reutilização de
  credenciais Git locais;
- distribuição permanecerá identificada como Preview verificável por DMG
  universal e SHA-256;
- produção continuará bloqueada por Developer ID, notarização, stapling, CI de
  release e validação em Mac limpo.

Gate concluído para publicação:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 156 testes executados, 0 falhas; 1 Keychain opt-in explicitamente omitido |
| `swift build -c release` | aprovado |
| `git diff --check` | aprovado |
| app universal | `arm64` e `x86_64`; `codesign --verify --deep --strict` aprovado |
| DMG e checksum | DMG verificado com sidecar SHA-256 correspondente |
| revisão pública | sem segredos, dados de máquina, caminhos locais ou referência externa |

Os gates de 89 testes acima são registros históricos dos incrementos em que
foram obtidos. Eles não reduzem o critério atual de 156 testes para este
refresh e para as próximas mudanças.

### 28.17 Incremento governado — atividade recente e reconhecimento local

Entregue:

- ordenação padrão por atividade recente, com o status de pipeline preservado
  como dimensão independente;
- tempo relativo, filtro `Recent`, marcador `NEW` e ponto de novidade para
  atualizações ainda não reconhecidas;
- reconhecimento individual ao selecionar o monitor, sem limpar novidades de
  outros repositórios;
- baseline silencioso no primeiro carregamento e na criação de monitor, evitando
  tratar estado preexistente como atividade nova;
- schema v3 do ledger com identidade sanitizada `MonitorID + runID`, baseline e
  reconhecimento mínimo, sem conteúdo de commit, URL ou credencial;
- migração de schema v2 que preserva dados e escolhe atividade recente como
  ordenação padrão;
- persistência de marcadores entre relançamentos sem disparar polling, refresh
  ou contornar backoff/rate limit;
- notificação de sucesso opcional, desligada por padrão e limitada a favoritos;
- precedência de recuperação que protege snapshots remotos, autenticação,
  rate limit e falhas de observação contra estado visual local obsoleto.

Critérios de aceitação verificados:

- `NEW` identifica novidade desde o baseline, nunca apenas sucesso ou falha;
- `Recent` e a ordenação tornam a última execução visível sem exigir que a
  pessoa acompanhe a tela continuamente;
- seleção reconhece apenas o item aberto e mantém os demais contadores;
- migration v2 e criação de monitor não produzem notificações retroativas;
- nenhum marcador pode substituir uma execução remota mais nova ou esconder
  indisponibilidade;
- todas as strings seguem en e pt-BR e a apresentação continua acessível.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 160 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| `git diff --check` | aprovado |
| persistência | schema v3, baseline e reconhecimento testados sem dados sensíveis |
| recuperação | precedência de snapshot, rate limit, autenticação e falhas coberta por testes |

### 28.18 Incremento entregue — janela única e ícone de aplicativo

Escopo e ownership:

- App lifecycle/window coordinator: uma única frente responsável por abertura,
  foco, restauração, fechamento e política de ativação do processo;
- recursos de aplicativo e empacotamento: uma frente separada responsável pelo
  asset premium, catálogo/formato de ícone macOS e validação no bundle;
- UI e testes: frentes separadas para rotas de abertura, acessibilidade e
  regressões de ciclo de vida;
- esta documentação: registra contrato, critérios e resultado dos gates após
  integração.

Contrato a implementar:

- dashboard possui uma identidade estável e somente uma instância;
- menu bar, atalhos, notificações e ações contextuais chamam a mesma operação
  abrir-ou-focar;
- pedidos concorrentes durante a abertura são coalescidos;
- instância existente é desminiaturizada, ativada e focada;
- abrir/restaurar dashboard mostra o app no Dock por política regular;
- dashboard aberto ou minimizado mantém o ícone no Dock;
- fechar dashboard retorna à política acessória e remove o ícone do Dock, sem
  encerrar menu bar, polling, notificações ou estado local;
- não há comportamento always-on-top;
- o ícone do Dock é um asset premium próprio, transparente e separado do
  símbolo monocromático da menu bar.

Critérios de aceitação verificados:

- múltiplos pedidos rápidos de abertura produzem uma única janela;
- abrir uma instância existente a traz para frente e a restaura se minimizada;
- Dock aparece ao abrir e continua ao minimizar;
- Dock desaparece somente ao fechar o dashboard;
- fechamento preserva monitoramento em segundo plano;
- bundle contém o ícone nativo correto e o asset lê bem em tamanhos de Dock;
- rotas de menu, notificação e atalho têm cobertura determinística;
- build release, testes completos, `git diff --check`, inspeção do bundle e QA
  manual de foco/Dock são aprovados antes de publicação.

Validação final:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 170 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| revisão independente | sem achados altos ou médios após correções |
| janela e Dock | singleton, coalescência, foco, minimização, timeout e fechamento cobertos |
| ícone | PNG 1024 RGBA, ICNS completo e bundle verificados |
| `git diff --check` e scan público | aprovados |

Estado: entregue e aprovado para empacotamento Preview.

### 28.26 Incremento entregue: centro de aprovações read-only

Escopo e ownership:

- domínio: priorizar `awaitingApproval` para apresentação, calcular a espera a
  partir da primeira detecção local e definir transições que criam ou cancelam
  lembretes, sem duplicar a fase normalizada;
- API e links: usar somente ambiente de deployment retornado por metadado
  confiável ou configuração explícita do monitor para `Production`, e construir
  o link HTTPS canônico do build no host Bitbucket permitido;
- UI e localização: apresentar o Centro de Aprovações, ambiente quando
  confiável, tempo de espera honesto, ação “Abrir no Bitbucket” e preferências
  de lembrete em 10 ou 15 minutos, completos em en e pt-BR;
- notifications e persistência: deduplicar lembretes por conta, monitor,
  execução e transição, persistir somente identificadores opacos e horários,
  e cancelar registros e notificações ao progredir, remover monitor ou
  desconectar conta;
- integração: preservar o contrato read-only, as validações de URL, a
  acessibilidade e as configurações existentes. Nenhum owner introduz escopo de
  escrita, aprovação, automerge ou tarefa remota.

Contrato estabilizado:

- a prioridade de aprovação reorganiza a apresentação, sem criar outro estado
  ou divergir da fase consumida por lista, detalhe, filtros, menu, polling e
  notificações;
- “aguardando” é tempo desde a primeira observação local da fase e não uma
  alegação sobre o instante remoto em que a aprovação ficou disponível;
- `Production` depende exclusivamente de metadado remoto confiável ou de
  configuração explícita, nunca de `main`, `master`, nome de branch, projeto ou
  etapa;
- abrir o build no Bitbucket é uma ação externa segura e read-only, limitada a
  HTTPS, host permitido e identificadores confiáveis;
- lembretes são opt-in, configuráveis para 10 ou 15 minutos, deduplicados e
  encerrados quando a aprovação deixa de existir;
- não há aprovação in-app, automerge, novas permissões Bitbucket ou mutação
  remota por notificação, link ou processo em segundo plano.

Critérios de aceite:

- uma aprovação pendente é apresentada antes de execuções ativas e saudáveis,
  mas conserva a mesma fase normalizada em todas as superfícies;
- o tempo de espera sobrevive ao relançamento quando o ledger permitido existir,
  é claramente descrito como detecção local e encerra ao sair de
  `awaitingApproval`;
- nenhum build recebe `Production` somente por usar `main` ou `master`; tanto
  o metadado confiável quanto a configuração explícita são cobertos por testes;
- a ação abre o build correto e recusa host, esquema, porta, credencial ou query
  que não passe pela allowlist;
- o lembrete não é entregue antes da opção, não duplica na mesma transição,
  usa somente 10 ou 15 minutos e cessa ao resolver, remover ou desconectar;
- acessibilidade, teclado, VoiceOver, en e pt-BR comunicam ação, prioridade,
  ambiente e a origem local do tempo sem depender só de cor;
- fixtures, logs, preferências e ledger não carregam token, URL externa,
  mensagem de commit, branch, etapa ou conteúdo de pull request.

Riscos e mitigação:

| Risco | Sinal | Mitigação |
| --- | --- | --- |
| falso `Production` | badge por convenção de branch | aceitar apenas metadado confiável ou escolha explícita |
| spam de lembrete | avisos repetidos da mesma espera | opt-in, intervalo fixo, dedupe e cancelamento por transição |
| link externo inseguro | host ou query não canônicos | construir/validar HTTPS e allowlist Bitbucket antes de abrir |
| deriva para mutação | ação de aprovação ou scope write | testes de contrato read-only e revisão de permissões |

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 251 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| build universal e assinatura | `arm64` e `x86_64`, `codesign --verify --deep --strict` e `Info.plist` aprovados |
| DMG e sidecar SHA-256 | DMG gerado, validado com `hdiutil` e sidecar aprovado |
| revisão final | sem achados após as correções |
| instalação local | Build Beacon build 5 instalado, com build 4 preservado como backup recuperável |
| QA da aplicação instalada | toggle Production por monitor e Approval reminder Off, 10 e 15 confirmados |

Estado: entregue e aprovado para empacotamento Preview.

### 28.19 Incremento entregue — interação e favoritismo da lista de repositórios

Escopo e ownership:

- UI da lista de repositórios: corrigir hit testing para que toda área textual
  ou vazia da linha selecione o monitor, mantendo a estrela como controle de
  ação exclusiva;
- estado/aplicação de favoritos: aplicar feedback otimista, persistir sem
  bloquear a UI e reverter de forma segura quando a persistência falhar;
- ordenação e apresentação: animar a mudança de posição causada por favorito,
  respeitando Reduce Motion e preservando a seleção por identidade do monitor;
- integrador: preencher as evidências da tabela de validação e atualizar a
  contagem pública de testes somente após os gates executados.

Critérios de aceitação verificados:

- nome, metadados e espaços vazios da célula selecionam a respectiva linha;
- a estrela tem hit target confiável, alterna apenas o favorito e não dispara
  seleção da linha;
- o feedback de favorito é imediato, enquanto persistência e snapshots não
  atrasam a interação;
- erro de persistência restaura o valor confirmado sem corromper a ordenação;
- favoritos sobem na lista com transição visual quando Reduce Motion está
  desativado e sem animação desnecessária quando está ativado;
- a seleção acompanha o mesmo `MonitorID` durante reorder e refresh.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| testes focados de favorito, rollback, concorrência, reorder e Reduce Motion | 47 testes executados, 0 falhas |
| `swift test --quiet` | 181 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| `git diff --check` | aprovado |
| revisão independente | sem achados altos ou médios após correções |

Estado: entregue e aprovado para empacotamento Preview.

### 28.20 Incremento entregue — alternância confiável de favoritos

Escopo e ownership:

- estado de favoritos: remover o bloqueio global que descartava uma alternância
  válida enquanto outra persistência estivesse em voo;
- persistência: serializar por `MonitorID` e valor desejado, preservando a
  intenção mais recente e impedindo que uma falha antiga reverta um clique novo;
- coleção: manter add/remove estruturais bloqueados enquanto favoritos estiverem
  pendentes, para não concorrer com a preferência otimista, e desabilitar a
  estrela explicitamente durante a mutação estrutural;
- UI: manter resposta imediata da estrela e animar somente reordenação real,
  com Reduce Motion respeitado;
- documentação: registrar os gates realmente executados, sem antecipar build
  ou revisão que ainda não ocorreram.

Critérios de aceitação verificados:

- cada clique válido de favoritar ou desfavoritar é aplicado imediatamente,
  mesmo durante uma persistência anterior;
- persistências pendentes de favoritos não desabilitam a estrela; somente uma
  mutação estrutural de add/remove a deixa explicitamente indisponível;
- favoritos de monitores distintos não bloqueiam a interação uns dos outros;
- uma falha antiga não substitui intenção posterior; se a última intenção falha,
  o valor exibido retorna ao último estado confirmado;
- add/remove de monitores não inicia enquanto existir favorito pendente;
- a animação existente ocorre somente quando a ordenação realmente muda e fica
  desativada quando Reduce Motion está ativo.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| testes focados de favorito, rollback, concorrência, reorder e Reduce Motion | 54 testes executados, 0 falhas |
| `swift test --quiet` | 188 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| `git diff --check` | aprovado |
| revisão independente | sem achados altos ou médios após correções |

Estado: entregue e aprovado para empacotamento Preview.

### 28.21 Incremento entregue — transação explícita da animação de favoritos

Escopo e ownership:

- modelo de apresentação: expor uma entrada síncrona que aplica imediatamente a
  intenção otimista e retorna a tarefa responsável pela persistência;
- UI da lista: iniciar essa entrada dentro da transação explícita do clique e
  remover a animação implícita vinculada ao conteúdo filtrado;
- acessibilidade: manter o mesmo resultado sem movimento quando Reduce Motion
  estiver ativo;
- documentação e integração: atualizar evidências, build, pacote e publicação
  depois da validação funcional na aplicação instalada.

Critérios de aceitação verificados:

- favoritar e desfavoritar entram deterministicamente na transação do gesto;
- o estado e a ordem mudam antes do retorno da entrada síncrona;
- persistência, rollback e semântica da intenção mais recente permanecem
  assíncronos e compatíveis com a API anterior;
- polling e outras mudanças de lista não disparam a animação do favorito;
- Reduce Motion elimina a transição sem alterar o resultado da ordenação.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| testes focados do modelo e métricas da lista | 55 testes executados, 0 falhas |
| `swift test --quiet` | 189 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| `git diff --check` | aprovado |
| revisão independente | sem achados altos ou médios |
| aplicação instalada | favoritar e desfavoritar confirmados manualmente |

Estado: entregue e aprovado para empacotamento Preview.

### 28.22 Incremento entregue — reabertura pelo Dock e Settings no dashboard

Escopo e ownership:

- ciclo de vida e coordenador de janela: tratar a solicitação de reabertura do
  macOS, inclusive o clique em um tile do Dock fixado sem dashboard, como mais
  uma rota para o coordenador único abrir-ou-focar;
- dashboard UI: incluir um controle nativo e acessível de Settings na toolbar,
  sem criar uma segunda superfície de configuração;
- documentação: manter README, decisão, aceite e a contagem pública atual
  coerentes com os gates executados.

Contrato estabilizado:

- clique no Dock com dashboard ausente cria o dashboard por meio do coordenador
  único;
- clique no Dock com dashboard aberto ou minimizado restaura, ativa e foca a
  instância existente;
- pedidos concorrentes continuam coalescidos e nunca criam dashboards
  duplicados;
- o controle de Settings abre ou foca a cena de ajustes existente, preservando
  as rotas pela menu bar e Command-Comma;
- o botão tem nome, dica e navegação por teclado adequados e usa texto
  localizado em inglês e pt-BR;
- fechar o dashboard preserva menu bar, polling, notificações e estado local.

Critérios de aceite verificados:

- um tile fixado no Dock deixa de ser inerte quando não há dashboard;
- reabrir pelo Dock não duplica janelas e restaura uma janela minimizada;
- Settings é alcançável tanto na toolbar do dashboard quanto pelas rotas
  existentes;
- a interação é coberta por testes determinísticos, além dos gates regulares
  do repositório.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 192 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| bundle universal ad-hoc | build, assinatura e validação do bundle aprovados |
| QA visual | reabertura após fechamento e Settings confirmados no bundle local; clique físico no tile do Dock não exposto pela automação |
| revisão independente | sem achados altos ou médios; achado baixo de ajuda contextual corrigido |
| `git diff --check` | aprovado na checagem consolidada |

Estado: entregue e aprovado para empacotamento Preview.

### 28.23 Incremento entregue: resolução auditável de estados Bitbucket

Escopo e ownership:

- contrato API e mapeamento: decodificar nome, resultado e estágio da pipeline,
  além do estado, resultado e gatilho da etapa, fornecendo-os ordenadamente ao
  resolvedor;
- domínio: centralizar a precedência de resultados terminais, estado remoto
  desconhecido, execução real, fila automática, espera por aprovação manual e
  parada sem execução;
- consumidores: usar a fase normalizada existente de modo consistente em
  filtros, lista, detalhe, saúde agregada, polling e notificações;
- testes: adicionar fixtures sanitizadas e cenários determinísticos sem dados
  de contas, repositórios, pessoas, commits ou URLs reais;
- documentação: registrar a decisão em `discussion.md` e explicar o suporte a
  aprovações manuais no README, sem antecipar contagem de testes ou resultado de
  gates.

Contrato estabilizado:

- resultados terminais explícitos têm precedência sobre o estado das etapas;
- valor remoto não reconhecido permanece `unknown` e nunca é apresentado como
  sucesso ou execução por inferência;
- nomes, resultados, estágios e tipos de gatilho são reconhecidos somente por
  allowlist explícita; combinação não reconhecida ou contraditória permanece
  `unknown`;
- em uma pipeline `IN_PROGRESS`, o estágio explícito `PAUSED` produz
  `awaitingApproval` diretamente;
- no estágio `RUNNING`, ou sem estágio explícito, a resolução ordenada das
  etapas dá precedência a uma etapa em execução; sem execução, a primeira etapa
  pendente com gatilho manual produz `awaitingApproval` e uma etapa `READY`
  automática produz `queued`;
- uma etapa com resultado `NOT_RUN` produz `stopped`;
- `awaitingApproval` usa a política de polling e a semântica de notificação da
  aprovação, não as de uma execução ativa.

Critérios de aceite verificados:

- a lista, o detalhe e os filtros apresentam a mesma fase para um mesmo
  snapshot;
- uma aprovação manual não aparece como `Running`;
- resultados terminais e desconhecidos preservam a precedência conservadora;
- `PAUSED`, `READY` e `NOT_RUN` são normalizados nas fases corretas;
- o filtro Attention inclui `stopped` e `unknown`, sem mudar indevidamente o
  escopo de filtros de execução ou aprovação;
- o scheduler usa a cadência correta para cada fase normalizada;
- notificações usam transições da fase resolvida, sem alerta duplicado ou
  classificação incompatível;
- en e pt-BR permanecem completos para toda nova string visível, se houver.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 202 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| build universal | `arm64` e `x86_64` aprovados |
| `codesign --verify --deep --strict` | aprovado |
| DMG e sidecar SHA-256 | DMG 1.0.0 gerado, validado com `hdiutil` e sidecar verificado |
| revisão independente | sem achados bloqueadores após a correção de P1 |
| `git diff --check` | aprovado |

Estado: entregue e aprovado para empacotamento Preview.

### 28.24 Incremento entregue: origem de execução e identificação de pull request

Escopo e ownership:

- domínio e API: adicionar a origem explícita `branch`, `pullRequest` ou
  `unknown` a `PipelineRun`; classificar somente
  `pipeline_pullrequest_target` como PR e somente `pipeline_ref_target` com
  `ref_type` `branch` como branch;
- contrato de apresentação: para PR, preservar o número e o trajeto
  `source → destination` recebidos no target; título, estado e link seguem
  como enriquecimento opcional e nunca mudam a classificação da execução;
- UI e localização: apresentar um badge textual localizado de origem na lista
  e no cabeçalho do detalhe, com fallback acessível e seguro para `unknown`;
- testes: cobrir a classificação dos targets, o caso de contexto de PR no
  commit sem reclassificar uma execução de branch, a apresentação e os
  fallbacks; nenhuma fixture contém dados reais;
- documentação e integração: manter este plano, a decisão e o README coerentes
  com o comportamento entregue, sem alterar a contagem pública de testes antes
  dos gates.

Critérios de aceite verificados:

- uma pipeline com `pipeline_pullrequest_target` mostra `PR #número` e
  `source → destination` quando o target fornecer esses dados;
- uma pipeline de `pipeline_ref_target` com `ref_type` `branch` permanece
  explicitamente identificada como branch, mesmo quando o commit tem contexto
  de PR associado;
- target ausente, novo ou incompatível resulta em origem `unknown`, sem inferir
  PR, branch ou merge;
- título, estado e link de PR ausentes por escopo, erro ou payload incompatível
  não ocultam nem reclassificam a origem derivada do target;
- lista, detalhe, VoiceOver e as localizações en e pt-BR comunicam a origem sem
  depender somente de cor ou ícone;
- estados de PR são mostrados apenas como enriquecimento confiável, e uma
  execução posterior na branch de destino não recebe indevidamente o rótulo de
  PR mesclada.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| testes focados de domínio, API e UI | classificação, apresentação, fallback e acessibilidade determinísticos aprovados |
| `swift test --quiet` | 214 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | build release aprovado |
| bundle universal e assinatura | `arm64` e `x86_64`, `codesign --verify --deep --strict` e `Info.plist` aprovados |
| DMG e sidecar SHA-256 | DMG 1.0.0 verificado e sidecar aprovado |
| revisões independentes | achados médios e P2 corrigidos e revalidados sem regressões |
| localizações | en e pt-BR aprovados |
| instalação local | bundle anterior substituído com backup recuperável; novo bundle iniciado e confirmado |
| `git diff --check` | aprovado |

Estado: entregue e aprovado para empacotamento Preview.

### 28.25 Incremento a implementar: autoria e contexto acionável na lista

Escopo e ownership:

- domínio e API: reutilizar apenas o autor já disponível no contexto de PR ou
  de commit, sem nova chamada, escopo, permissão ou persistência;
- contrato de apresentação: para `pullRequest`, escolher somente o autor da
  PR; para `branch`, somente o autor do commit; para `unknown`, não apresentar
  uma identidade inferida;
- UI e localização: substituir o workspace na linha resumida por autor,
  fallback localizado quando uma origem conhecida não tiver autor, e manter o
  workspace somente no detalhe; preservar a idade relativa à direita como
  recência e mostrar na terceira linha a duração do último build quando
  disponível, combinada à etapa contextual para `failed`, `running`, `queued`
  e `awaitingApproval`;
- testes: cobrir precedência de autor por origem, fallback, ausência de autor
  em origem desconhecida, remoção do workspace da lista, preservação no
  detalhe, condições da terceira linha, VoiceOver e en/pt-BR;
- documentação e integração: manter esta decisão, o README e os critérios de
  aceite alinhados ao contrato, sem atualizar contagens de validação antes dos
  gates.

Critérios de aceite:

- uma execução de PR mostra apenas o autor da PR, sem substituí-lo pelo autor
  do commit;
- uma execução de branch mostra apenas o autor do commit, sem usar contexto de
  PR associado;
- origem `unknown` não mostra identidade inferida; origem conhecida sem autor
  mostra fallback localizado explícito;
- o workspace não aparece na linha resumida, mas permanece presente no detalhe
  e nas superfícies de configuração;
- a idade relativa à direita permanece o sinal de recência e não é reutilizada
  como duração;
- duração disponível aparece na terceira linha, inclusive em uma execução
  saudável; duração ausente não gera texto substituto enganoso;
- quando houver etapa acionável e duração, ambas compartilham uma terceira
  linha legível; sem duração, a etapa continua presente para falha, execução,
  fila ou espera de aprovação; sem os dois valores, a terceira linha não é
  criada;
- texto, não apenas cor, comunica origem, autoria e fallback à navegação por
  teclado e VoiceOver;
- o incremento não cria requests adicionais nem altera permissões ou dados
  persistidos.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 230 testes executados, 0 falhas; 1 Keychain opt-in omitido |
| `swift build -c release` | aprovado |
| localizações | en e pt-BR validados com `plutil` |
| `git diff --check` | aprovado |
| build universal e assinatura | `arm64` e `x86_64`, `codesign --verify --deep --strict` aprovados |
| DMG e SHA-256 | artefato e sidecar verificados |
| instalação local | Build Beacon build 4 instalado |
| QA visual | autor correto de branch, fallback honesto de PR, duração e etapa combinadas, idade relativa separada |
| revisões independentes | sem achados bloqueadores |

Estado: entregue e aprovado para empacotamento Preview.

### 28.27 Incremento a implementar: `Approve and merge` opt-in

Escopo e ownership:

- credenciais: adicionar `WriteCredentialStore` isolado, com service Keychain
  diferente da credencial read e scopes exatos
  `read:user:bitbucket`, `read:pullrequest:bitbucket` e
  `write:pullrequest:bitbucket`; exigir `read:pullrequest:bitbucket` também na
  credencial read-only quando Action Mode estiver habilitado;
- domínio: modelar elegibilidade, confirmação, dois preflights imutáveis,
  single-flight por PR e resultados `confirmed`, `rejected`, `partial` e
  `unknown`, sem expor o token à monitoração;
- API: implementar dois preflights remotos completos, cada um consultando a
  pipeline exata com a credencial de monitoramento e a PR/HEAD com a credencial
  de ação, além de `POST approve`, `POST merge`, acompanhamento da task de `202`
  e GET final da PR;
- UI: opt-in por monitor com default `false`, confirmação foreground por ação,
  apresentação completa das precondições, publicação das fases reais de
  revalidação, aprovação, merge e verificação, e feedback honesto para resultado
  parcial ou desconhecido;
- persistência: migrar configuração de forma reversível com allow write por
  monitor desligado; não persistir audit trail de ações, SHA, payload ou erro
  remoto nesta primeira versão;
- integrador: manter polling, notificações, lembretes, menu e deep links fora do
  grafo de dependência da credencial write e de qualquer endpoint mutável.

Contrato estabilizado:

- a única mutação permitida é `Approve and merge` para PR `OPEN`, não draft,
  cujo source HEAD corresponda ao commit da execução monitorada mais recente e
  `succeeded`;
- habilitação global ou credencial write não bastam: o monitor exato precisa
  estar explicitamente allowlisted, com default `false` em instalação e
  migração;
- a credencial write é um segundo item Keychain e aceita somente
  `read:user:bitbucket`, `read:pullrequest:bitbucket` e
  `write:pullrequest:bitbucket`; o scope de usuário valida a identidade antes de
  salvar a credencial e antes de qualquer mutação; o token read não é promovido
  nem substituído;
- o token de monitoramento continua read-only, mas precisa de
  `read:pullrequest:bitbucket` quando Action Mode estiver habilitado;
- toda tentativa nasce de gesto humano com o app ativo e confirmação mostrando
  workspace, repo, PR, branches, source HEAD e build;
- o primeiro preflight consulta remotamente a pipeline exata com o token de
  monitoramento e confirma execução, commit, associação mais recente e resultado
  `succeeded`; com o token de ação, revalida PR `OPEN`, não draft, branches e
  source HEAD; divergência executa zero POST;
- `POST approve` ocorre uma vez, sem retry; depois dele, um segundo preflight
  remoto repete todas as garantias com as duas credenciais antes de permitir
  `POST merge` uma vez, sem retry;
- `200` exige GET final; `202` acompanha somente a task retornada até estado
  terminal e depois exige GET final; sucesso existe apenas com PR `MERGED`;
- timeout, `5xx`, payload incompatível, falha de task ou GET final e qualquer
  outra ambiguidade após POST resultam em `unknown`, sem retry; approve
  confirmado sem merge é `partial` e não provoca unapprove automático;
- a UI publica progresso real durante revalidação, aprovação, merge e
  verificação, sem inventar percentual ou conclusão antecipada;
- nenhum background, polling, relaunch, notificação, lembrete ou deep link pode
  iniciar ou continuar a ação; no máximo abre o dashboard;
- nesta primeira versão não há audit persistido. Configuração mínima e segredo
  no Keychain são as únicas novas retenções locais.

Critérios de aceite:

- sem segundo token e allow por monitor, a aplicação conserva exatamente o
  comportamento read-only e oferece somente abrir a PR no Bitbucket;
- token read e write têm services Keychain diferentes; testes de arquitetura
  provam que scheduler, notifications, reminders e link routing não resolvem
  `WriteCredentialStore`;
- PR merged, declined, draft, sem HEAD confiável, com branches divergentes,
  build running/failed/unknown ou run em commit anterior nunca apresenta ação
  elegível;
- a confirmação é obrigatória em cada ação, acessível por teclado e VoiceOver,
  e nenhum link ou evento consegue confirmá-la programaticamente;
- mudança de estado, branch ou HEAD em qualquer preflight aborta sem merge; o
  segundo preflight é obrigatório mesmo quando approve retorna sucesso;
- testes de transporte provam zero retry para ambos os POSTs, bloqueio de
  double-click e single-flight por PR;
- `200`, `202`, task terminal, GET final, `401`, `403`, `409`, `429`, timeout,
  `5xx` e payload incompatível produzem feedback conservador e determinístico;
- a UI nunca afirma merge até GET final `MERGED` e nunca sugere que estado
  `unknown` é falha segura para repetir;
- migração mantém allow write desligado e falha ao salvar configuração ou
  Keychain faz rollback local sem habilitação parcial;
- nenhum token, Authorization, SHA, payload, URL, erro bruto ou registro da
  ação aparece em config, ledger, logs, notificações, diagnostics ou fixtures;
- strings en e pt-BR deixam claro que o merge é remoto, requer confirmação e
  pode terminar com resultado desconhecido.

Riscos e mitigação:

| Risco | Mitigação |
| --- | --- |
| PR ou commit errado | allow por monitor, confirmação e dois preflights com HEAD/branches/run commit |
| double-submit | single-flight, botão desabilitado e zero retry automático |
| approve concluído e merge falho | estado parcial explícito, sem unapprove automático |
| timeout após mutação | resultado `unknown`, GET fresco e bloqueio de repetição cega |
| token write usado pelo monitoramento | Keychain service, protocolo e dependency graph separados |
| permissão excessiva | aceitar somente os três scopes mínimos da credencial de ação; manter a credencial de monitoramento read-only |
| mutação disparada fora de contexto | foreground obrigatório; notification/deep link apenas abrem a UI |
| retenção indevida | nenhum audit persistido; config mínima e segredo somente no Keychain |

Gates antes de entrega:

- contract tests dos endpoints públicos de approve, merge, task e GET final;
- testes de preflight e concorrência cobrindo toda divergência e erro descritos;
- testes de Keychain e redaction para as duas credenciais;
- testes de identidade, scopes exatos e preflights remotos com as duas
  credenciais;
- revisão de produto e segurança do modal, scopes, estado parcial e unknown;
- suíte completa, release, localizações, `git diff --check` e QA da aplicação
  instalada.

Evidência final desta rodada:

| Gate | Resultado |
| --- | --- |
| `swift test --quiet` | 305 testes executados, 0 falhas; 2 integrações Keychain opt-in omitidas |
| `swift build -c release` | aprovado |
| localizações | en e pt-BR validados com `plutil`, chaves equivalentes e sem duplicidade |
| `git diff --check` | aprovado |
| build universal e assinatura | build 6, `arm64` e `x86_64`, `codesign --verify --deep --strict` aprovados |
| DMG e SHA-256 | artefato validado com `hdiutil` e sidecar confirmado com `shasum` |
| instalação local | Build Beacon build 6 instalado e iniciado em `/Applications` com backup recuperável |
| revisão do contrato de ação | três scopes mínimos, identidade, dois preflights remotos, ambiguidades e progresso real alinhados |
| revisão independente final | sem achados bloqueadores após correções e regressões específicas |

Estado: implementação concluída e validada para o Build Beacon build 6.

### 28.28 Incremento entregue: migração schema 4 para 5 e troca local segura

Incidente de referência:

- uma troca local encontrou configuração persistida em schema 4;
- o build candidato usava schema 5, mas o migrador possuía rotas explícitas
  apenas para schemas 1, 2 e 3;
- a persistência falhou de modo conservador, preservou o arquivo e seu backup e
  não alterou o Keychain, porém a sessão não recuperou conta e monitores;
- o gate de instalação limpa não detectou a lacuna porque criou diretamente um
  estado no schema corrente;
- nenhum dado privado, caminho pessoal, identificador real ou segredo faz parte
  deste registro.

Escopo implementado:

- persistência: foram criados tipos históricos imutáveis para o envelope e a
  configuração v4, sem reutilizar o modelo corrente como contrato de migração;
- migração: foi adicionada rota explícita e determinística do schema 4 para 5,
  com backup anterior à primeira escrita e falha sem overwrite quando o payload
  não satisfizer invariantes;
- defaults: novos campos do schema 5 permanecem em valores seguros, com Action
  Mode e allowlist de mutação desligados, sem alterar preferências já existentes;
- fixture: uma cópia sanitizada representativa da topologia local real preserva
  quantidades, tipos de target, flags e relações, mas substitui conta, e-mail,
  workspace, repositório, branch, caminhos e demais valores privados por dados
  sintéticos; tokens e conteúdo de commit ficam excluídos;
- operação local: build e schemas atuais foram inventariados antes da troca; o
  bundle e a persistência compatível foram preservados para rollback como par;
- QA: upgrade e rollback foram testados, e conta e monitores foram confirmados
  após o lançamento com o Keychain intacto;
- documentação: somente versões, resultados e contagens sanitizadas são
  registradas, nunca payloads, valores de conta, nomes privados ou caminhos
  pessoais.

Critérios de aceite verificados:

- schema 4 válido migra para schema 5 e cria backup com permissões restritivas
  antes de substituir o arquivo;
- a migração preserva identidade lógica da conta, conjunto e targets dos
  monitores, favoritos, visibilidade, marcação de produção, preferências de
  apresentação, notificações, histórico, atividade não vista e esperas de
  aprovação representadas no schema 4;
- campos exclusivos do schema 5 recebem defaults documentados e seguros, sem
  habilitar ação remota por migração;
- payload v4 inválido, corrompido ou incompatível continua fail-closed, mantém o
  original recuperável e não permite save parcial;
- testes usam fixture sanitizada com a mesma forma relevante do estado de
  upgrade, além de casos mínimos, corrupção e schema futuro;
- o gate executa upgrade sobre uma cópia do estado anterior e não considera
  instalação limpa como evidência suficiente;
- o backup registra versão/build do app e schema da configuração, sem copiar ou
  revelar itens do Keychain;
- rollback restaura bundle e configuração compatíveis e confirma que o app
  anterior volta a abrir o estado esperado;
- depois do lançamento do candidato, uma verificação explícita confirma a conta
  esperada e todos os monitores antes da promoção;
- falha em migração, upgrade, lançamento, confirmação ou rollback interrompe a
  substituição e restaura o par preservado.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| rollback real | build 5 com schema 4 carregou a conta e 11 monitores |
| migração representativa opt-in | cópia sanitizada da topologia real com 11 monitores migrou para schema 5 |
| `swift test --quiet` | 315 testes executados, 0 falhas; 3 testes opt-in omitidos |
| `swift build -c release` | aprovado |
| localizações e diff | catálogos aprovados e validação de diff sem erro |
| bundle e assinatura | universal `arm64` e `x86_64`; `codesign --verify --deep --strict` aprovado |
| DMG e SHA-256 | artefato e sidecar aprovados |
| instalação local | build 7 instalado; schema 5, conta presente, 11 monitores e flags de ação `false` |
| Keychain | itens esperados permaneceram presentes durante upgrade e rollback |
| backup recuperável | diretório `0700`, arquivos `0600`; caso de backup idêntico corrigido para reafirmar `0600` |
| QA visual | dashboard conectado confirmado na aplicação instalada |

Estado: implementação concluída e validada para o Build Beacon build 7. A rota
schema 4 para 5, o upgrade representativo, o rollback compatível e os gates de
distribuição foram aprovados.

### 28.29 Incremento entregue: fila `Ready to Merge` para PRs verdes

Escopo e ownership:

- domínio e sincronização: separar a candidata de PR verde da autorização de
  ação, exigir relação confiável entre a execução `succeeded`, PR `OPEN`, não
  draft, source HEAD e branches antes de declarar `Ready to Merge`;
- UI: expor badge e filtro/fila de candidatas independentemente de Action Mode
  ou opt-in, com CTA contextual no resumo e no detalhe;
- ação: reutilizar, sem ampliar, o contrato isolado de `Approve and merge`,
  incluindo confirmação e dois preflights; nenhum caminho de polling recebe
  acesso à credencial write;
- documentação e testes: registrar estados distinguíveis, localizações en e
  pt-BR, acessibilidade e regressões de contexto incompleto.

Contrato estabilizado:

- uma candidata pode permanecer visível sem Action Mode, token write ou opt-in
  por monitor; disponibilidade da fila não concede capacidade de mutação;
- `Ready to Merge` exige contexto completo e atual da mesma PR `OPEN`, não
  draft, source HEAD igual ao commit da execução monitorada mais recente com
  resultado `succeeded`, além de branches identificadas;
- ausência, ambiguidade ou desatualização de PR, HEAD, branches ou associação
  com a execução impede a afirmação de prontidão. O item conserva somente o
  estado que pode ser comprovado e pode oferecer abrir a PR no Bitbucket;
- ação totalmente configurada e monitor allowlisted: CTA `Approve and merge`;
  somente opt-in local ausente: CTA `Enable and review`; Action Mode,
  credencial ou pré-requisito de configuração ausente: CTA `Set up approve and
  merge`;
- `Enable and review` e `Set up approve and merge` apenas abrem configuração ou
  revisão. Não aprovam, não fazem merge e não alteram permissões
  silenciosamente;
- o CTA de mutação ainda exige gesto foreground, confirmação e os dois
  preflights remotos completos imediatamente antes dos POSTs. Status verde,
  fila, badge, notificação, deep link, relaunch e polling não autorizam nem
  iniciam mutação;
- checks de merge, aprovação independente, conflito ou qualquer bloqueio
  retornado pelo Bitbucket continuam fonte de verdade após os preflights.

Critérios de aceite:

- uma PR verde com contexto completo aparece na fila `Ready to Merge` e no
  badge mesmo sem Action Mode ou opt-in daquele monitor;
- uma execução verde sem PR aberta associada, com HEAD divergente, PR draft,
  contexto ausente ou associação ambígua não é declarada pronta;
- os três CTAs são escolhidos somente pelo estado configurado e são claros para
  teclado e VoiceOver, com strings completas em en e pt-BR;
- o CTA `Approve and merge` não aparece como habilitado para uma candidata que
  não cumpra o contrato de ação, e todos os caminhos de configuração preservam
  o estado read-only até a decisão explícita da pessoa usuária;
- os testes cobrem transições após refresh, perda de elegibilidade, filtros,
  seleção estável e ausência de mutação em qualquer caminho não foreground;
- não há novo scope, nova credencial, endpoint write, automerge ou alteração de
  retenção local neste incremento.

Gates executados:

- testes de modelo e view model para candidata, contexto incompleto e seleção
  dos três CTAs;
- testes de apresentação, filtros, acessibilidade e localizações en e pt-BR;
- regressões de isolamento garantindo que polling, notificações e deep links
  não conseguem iniciar `Approve and merge`;
- suíte completa, build release, `git diff --check`, bundle universal, assinatura,
  DMG, SHA-256 e QA da aplicação instalada.

Validações do incremento:

| Gate | Resultado |
| --- | --- |
| fila, CTAs e contexto incompleto | cobertos por testes de modelo, apresentação e interação; PR bem-sucedida sem contexto completo expõe somente `Set up approve and merge…` na linha e na toolbar, sem badge `Ready to Merge` ou target de mutação |
| corrida de habilitação | single-flight corrigido; teste confirma zero preflight antes de a persistência do opt-in terminar |
| `swift test --quiet` | 328 testes executados, 0 falhas; 3 integrações opt-in omitidas |
| `swift build -c release` | aprovado |
| localizações | catálogos en e pt-BR validados, com paridade de chaves |
| `git diff --check` | aprovado |
| bundle e assinatura | build 8 universal `arm64` e `x86_64`; `codesign --verify --deep --strict` refeito e aprovado após as correções |
| DMG e SHA-256 | DMG, `hdiutil` e sidecar SHA-256 refeitos e aprovados após as correções |
| upgrade local | build 7/schema 5 para build 8 preservou schema 5, conta, 11 monitores, Action Mode e opt-ins existentes |
| backup recuperável | diretório `0700`, arquivos `0600` |
| QA visual | aplicação ativa, dashboard conectado e atualizando; CTA seguro confirmado na linha e na toolbar de PRs legadas sem contexto completo, sem badge de prontidão |

Estado: implementação concluída e validada para o Build Beacon build 8. A fila
permanece informativa mesmo sem capacidade local de ação, e uma PR verde só é
declarada pronta quando o contexto atual completo sustenta essa afirmação.

### 28.30 Entrega a validar: `1.0.0 Preview 7`, build 8

Decisão de versionamento aplicada a esta entrega:

- toda publicação GitHub que inclua mudança de aplicativo incrementa o build e
  o ordinal Preview da linha de produto atual;
- a versão SemVer do bundle muda somente após decisão explícita de novo marco
  de produto;
- push apenas documental ou de governança, sem artefato de aplicativo, não
  exige versão nova de produto;
- enquanto a assinatura for ad-hoc e não houver notarização, a publicação usa
  somente prerelease `vX.Y.Z-preview.N`, sem tag estável;
- tags e assets publicados são imutáveis: não reutilizar tag nem sobrescrever
  DMG ou sidecar existentes.

Classificação desta entrega:

- a publicação anterior foi `1.0.0 Preview 6`;
- versão candidata: `1.0.0 Preview 7`;
- tag candidata: `v1.0.0-preview.7`;
- build candidato: `8`.

Critérios antes de publicação:

- confirmar que os gates de código, localizações, distribuição e QA foram
  executados para o commit exato da entrega;
- confirmar que a tag candidata não existe e que nenhum asset será substituído;
- publicar exclusivamente como prerelease enquanto a assinatura não for
  Developer ID notarizada;
- associar o DMG e o SHA-256 correspondentes ao build 8, sem alterar releases
  anteriores.

Estado: gates de código, distribuição e QA concluídos para `1.0.0` build 8.
Entrega integrada no `main` e publicada como `v1.0.0-preview.7`, com DMG e
sidecar SHA-256 verificados.
