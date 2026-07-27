# cync

[English README](./README.md)

[Claude Code](https://docs.anthropic.com/claude-code) 와 [Codex CLI](https://developers.openai.com/codex) 설정을 여러 기기에서 한 줄로 동기화하는 설치 도구.

**도구** 와 **데이터** 를 의도적으로 분리합니다:

- **도구 (public, 공용)** — 이 repo, `gourderased/cync`. 설치 스크립트와 `claude`/`codex` 쉘 래퍼가 들어있음. 모든 사용자가 같은 곳에서 설치.
- **데이터 (private, 본인 것)** — 본인의 `settings.json`, `instructions/`, `commands/`, `agents/`, `skills/` 는 본인 GitHub 계정의 private repo 에 들어감. cync 는 심링크와 쉘 래퍼로 연결만 해줌.

## 두 툴 사이에서 공유되는 것

Claude Code 와 Codex 는 설정 포맷이 서로 다릅니다. 파일 하나로 양쪽을 먹일 수 있는 것만 공유하고, 나머지는 각 툴에서 각자 관리합니다.

| 항목 | 공유 | 방식 |
|---|---|---|
| `skills/` | O | 두 툴 다 `SKILL.md` 포맷이 같음 → 심링크 |
| `instructions/common.md` | O | `CLAUDE.md` 와 `AGENTS.md` 로 각각 생성 |
| `agents/`, `commands/`, `settings.json` | X | 포맷이 달라 각 툴에서 관리 |

지시서를 심링크가 아니라 **생성**하는 이유: Codex 의 `AGENTS.md` 에는 다른 파일을 불러오는 import 문법이 없어서, 공통 부분이 이어붙은 실제 파일이어야 합니다.

```
instructions/common.md + instructions/claude.md  →  ~/.claude/CLAUDE.md
instructions/common.md + instructions/codex.md   →  ~/.codex/AGENTS.md
```

생성된 파일은 직접 고치지 마세요. 다음 실행 때 덮어써집니다. `instructions/` 를 고치면 됩니다.

`~/.codex/skills` 는 Codex 자체 스킬(`.system/`)이 들어있는 디렉토리라 통째로 심링크하지 않고, 스킬 하나씩 개별 심링크합니다.

## 동작 원리

```
                    ┌──────────────────────────────────────────┐
                    │  GitHub                                  │
                    │                                          │
                    │  gourderased/cync         (PUBLIC)       │  ← 설치 도구
                    │  ├ install / uninstall                   │
                    │  ├ lib/{setup, install, uninstall,       │
                    │  │      claude-wrapper, sync-targets}.sh │
                    │  └ template/                             │
                    │                                          │
                    │  <user>/<config-repo>     (PRIVATE)      │  ← 본인 설정
                    │  ├ settings.json                         │
                    │  ├ instructions/{common,claude,codex}.md │
                    │  └ commands/  agents/  skills/           │
                    └────────────────────┬─────────────────────┘
                                         │
                                         │  HTTPS (gh CLI)
                                         │
            ┌─────────────┬──────────────┼──────────────┬─────────────┐
            ▼             ▼              ▼              ▼             ▼
        [기기 1]       [기기 2]        [기기 3]        ...         [기기 N]

       ~/.cync/                       설치 도구 clone (래퍼가 자동 pull)
       ~/<config-repo>/               개인 설정 clone (래퍼가 자동 pull)
       ~/.claude/{settings.json,...}    → ~/<config-repo>/ 로 심링크
       ~/.claude/CLAUDE.md            instructions/ 에서 생성
       ~/.codex/AGENTS.md             instructions/ 에서 생성
       ~/.codex/skills/*              → ~/<config-repo>/skills/ 로 개별 심링크
       ~/.zshrc | ~/.bashrc           BEGIN cync 블록이 래퍼를 source
```

`claude` 또는 `codex` 를 실행할 때마다 쉘 래퍼가 먼저 동작:

```
$ claude   (codex 도 동일)
   │
   ▼   throttle: 마지막 sync 가 60초 이내면 skip
   │
   ▼   git pull ~/.cync                 (설치 도구 최신화)
   │   git pull ~/<config-repo>         (다른 기기의 설정 변경 가져옴)
   │   instructions/ → CLAUDE.md, AGENTS.md 생성
   │   skills/ → ~/.codex/skills 개별 심링크
   │   플러그인 HEAD 체크 (변경 시 안내만, claude 만)
   │
   ▼   command claude "$@"              (실제 CLI 실행)
```

throttle 마커는 두 래퍼가 공유합니다. `claude` 직후에 `codex` 를 켜면 방금 pull 한 설정이 이미 최신이므로 다시 pull 하지 않습니다.

한 기기에서 `settings.json` 을 수정하거나 슬래시 커맨드를 추가하고 push 하면, 다른 기기에서 다음 `claude` 실행 시 자동 반영. 수동 sync 없음, 기기별 drift 없음.

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/gourderased/cync/main/install | bash
```

**사내 방화벽이 `raw.githubusercontent.com` 을 차단하나요?** `github.com` 으로 가는 git fallback 사용 (대부분 회사에서도 막혀있지 않음):

```bash
git clone https://github.com/gourderased/cync.git ~/.cync
bash ~/.cync/lib/setup.sh
```

설치 스크립트가 하는 일:

1. `~/.cync/` 로 자기 자신을 clone.
2. 모든 prereq (`git`, `node`, `claude`, `gh`) 한 번에 체크하고 빠진 게 있으면 배포판별 설치 명령을 출력.
3. gh 인증 안 돼있으면 `gh auth login` 실행 — device-code 흐름이라 SSH/headless 서버에서도 동작.
4. 아래 인터랙티브 단계들 진행.
5. `~/.claude/{settings.json, commands, agents, skills}` 를 config repo 로 심링크.
6. `instructions/` 에서 `~/.claude/CLAUDE.md` 생성. Codex 가 깔려 있으면 `~/.codex/AGENTS.md` 도 생성하고 스킬을 개별 심링크.
7. `~/.zshrc` 또는 `~/.bashrc` 에 cync 블록 추가 (claude/codex 래퍼 source).

설치 끝나면 쉘 리로드 후 `claude` 실행.

## 설치 흐름

각 프롬프트는 시안색 박스로 명확히 구분됩니다. 대부분 default 가 안전한 선택이라 엔터만 쳐도 무방.

### 1 — config repo 선택

본인 GitHub 의 모든 repo 가 번호 매겨진 메뉴로 나오고, "Create new private repo" 옵션과 quit 옵션도 함께. 번호 입력하거나 `Q` 로 변경 없이 종료.

### 2 — 새 repo 이름 *(create-new 경로만)*

필수 입력 + 형식 검증. 이미 같은 이름의 repo 가 본인 계정에 있으면 즉시 알려주고 재입력 — 한참 진행 후 실패하지 않음.

### 3 — 새 repo seed *(create-new 이고 ~/.claude 에 진짜 파일이 있을 때만)*

본인이 이미 Claude Code 를 쓰고 있던 흔적이 있으면 새 repo 를 어떻게 채울지 묻기:

- **`u` 본인 설정 사용 (default, 추천)** — 현재 `settings.json`, `commands/` 등을 그대로 새 repo 에 push. 빠진 항목은 템플릿에서 채움. (`CLAUDE.md` 는 생성물이라 제외 — 템플릿의 `instructions/` 가 들어감)
- **`t` cync 템플릿만 사용** — 빈 starter (model=opus, 빈 permissions, 빈 plugins). 본인 기존 파일은 `~/.claude/backups/` 로 이동.

### 4 — public repo 확인 *(public repo 를 선택했을 때만)*

config repo 로 public repo 를 고르면 빨간 경고 + `y` 명시적 입력 요구. API 토큰이나 개인 프롬프트가 GitHub 에 공개되는 사고 방지.

### 5 — clone 위치

기본값은 `~/<repo-name>`. 잘못된 입력 (부모 폴더 없음, 다른 git 아닌 디렉토리, 다른 origin 가리키는 git repo) 시 거부 사유와 함께 재입력 루프. `~/foo` 는 `$HOME/foo` 로 자동 전개.

이전 시도에서 만들어진 stale clone 이 있어서 history 가 origin 과 diverge 한 상태면 (이전 cancel 후 GitHub repo 재생성된 케이스), divergence 감지해서 `r` reset / `p` 다른 경로 / `a` abort 선택지 제공.

### 6 — 기존 설정 덮어쓰기 확인 *(~/.claude 에 충돌 항목이 있을 때만)*

`~/.claude/` 에 이미 실파일이나 외부 심링크가 있어서 config repo 와 겹치면, 항목 목록을 보여주고 `[y/N]` 으로 백업 후 심링크 교체 동의 받음. 기본값 N.

### 7 — git 사용자 정보 설정 *(global git config 에 user.name 또는 user.email 이 비어있을 때만)*

cync 가 GitHub 프로필에서 가져온 값으로 자동 설정 제안. 이게 없으면 첫 수동 commit (슬래시 커맨드 추가, `instructions/` 편집 등) 이 "Author identity unknown" 으로 실패함.

## 다른 기기 추가

같은 설치 명령을 다른 기기에서 실행. 메뉴에서 "Create new" 대신 본인 기존 config repo 선택. cync 가 clone + 심링크 + 래퍼 등록까지 알아서 — 즉시 같은 환경.

사내 리눅스 서버라서 `raw.githubusercontent.com` 차단? 위 **설치** 섹션의 `git clone` fallback 사용. 그 이후 흐름은 동일.

## 평소 사용

그냥 `claude` 입력. 실제 바이너리 호출 전에 래퍼가:

1. `~/.cync` 에서 `git pull --ff-only` (설치 도구 최신화).
2. config repo 에서 `git pull --ff-only` (다른 기기의 변경 가져옴).
3. `settings.json → enabledPlugins` 의 각 플러그인 HEAD 체크. 원격이 변경됐으면 `/plugin update` 를 권하는 안내 한 줄만 출력 — 플러그인 cache 나 registry 는 직접 건드리지 않음 (그건 Claude Code 의 몫).

위 네트워크 작업이 실패하면 (오프라인, 느림, 차단) 노란 경고 한 줄만 출력하고 계속 진행 — `claude` 자체는 정상 실행.

### Sync throttle

매번 `claude` 호출마다 네트워크 가지 않도록 throttle. 마지막 sync 가 60초 이내면 다음 `claude` 는 네트워크 skip.

```bash
# 한 번만 throttle 우회 (claude 실행 없이 지금 바로 sync)
cync-sync

# 항상 sync (throttle 끔)
CYNC_SYNC_INTERVAL=0 claude

# interval 변경 (초 단위, default 60)
CYNC_SYNC_INTERVAL=300 claude        # 5분에 한 번만
```

rc 파일 (cync 블록 밖에) `export CYNC_SYNC_INTERVAL=...` 추가하면 영구 적용.

### 변경사항 push 하기

슬래시 커맨드 추가, `instructions/` 수정, 서브에이전트 추가 등의 작업을 하면 config repo 의 파일이 변경됩니다. 다른 기기로 전파하려면 push 해야 함. `cd ... && git add && git commit && git push` 매번 치기 귀찮으니 두 명령을 wrapper 에 추가:

```bash
cync-status                        # 미커밋 변경 + remote 대비 ahead/behind + 최근 커밋
cync-push                          # 자동 메시지: "cync-push from <host> at <time>"
cync-push "add /foo command"       # 메시지 직접 지정
cync-sync                          # throttle 무시하고 지금 바로 전부 pull
cync-doctor                        # 전체 연결 상태 read-only 점검
```

변경사항 없으면 `nothing to push` 출력하고 깔끔히 종료. push 실패 시 (네트워크 다운, divergent branch 등) 다음 단계 힌트 출력 — 오프라인으로 push 만 실패해서 남은 커밋도 다음 실행 때 알아서 감지해 push. 변경을 GitHub 에 올리고 싶을 때 명시적으로 한 번 치면 됨 — 그게 전부.

깜빡해도 괜찮음: config repo 에 미커밋/미push 작업이 있으면 `claude` 실행 때 한 줄 리마인더가 뜨고, 다른 기기의 변경이 auto-pull 로 들어오면 어떤 파일이 왔는지 한 줄로 알려줌.

## 디렉토리 구조

```
~/.cync/                                   # 이 repo (설치 도구)
├── install                                # curl|bash 진입점
├── uninstall                              # 제거 진입점
├── lib/
│   ├── setup.sh                           # 인터랙티브 init/join 흐름
│   ├── install.sh                         # 심링크 + rc 블록
│   ├── uninstall.sh                       # 인터랙티브 제거
│   ├── claude-wrapper.sh                  # claude / codex 쉘 함수
│   └── sync-targets.sh                    # 지시서 생성 + Codex 스킬 링크
├── template/                              # 새 config repo seed
└── tmp/                                   # 임시 빌드 디렉토리

~/<your-config-repo>/                      # 본인 private repo (데이터)
├── settings.json                          # Claude 전용
├── instructions/
│   ├── common.md                          # 두 툴 공통
│   ├── claude.md                          # Claude 전용
│   └── codex.md                           # Codex 전용
├── commands/                              # Claude 전용
├── agents/                                # Claude 전용
└── skills/                                # 두 툴 공유

~/.claude/                                 # Claude Code 가 읽는 곳
├── settings.json   -> ../<your-config-repo>/settings.json
├── CLAUDE.md                              # 생성됨 (common + claude)
├── commands        -> ../<your-config-repo>/commands
├── agents          -> ../<your-config-repo>/agents
├── skills          -> ../<your-config-repo>/skills
├── cync-last-sync                         # throttle 마커 (codex 와 공유)
└── plugin-sync-state/                     # 플러그인별 HEAD 추적

~/.codex/                                  # Codex 가 읽는 곳
├── AGENTS.md                              # 생성됨 (common + codex)
└── skills/
    ├── .system/                           # Codex 자체 스킬 (안 건드림)
    └── <skill>     -> ../<your-config-repo>/skills/<skill>
```

## 제거

```bash
bash ~/.cync/uninstall
```

질문 두 개:

1. **`~/.claude/` 를 어떻게 남길까요?**
   - **`m` Materialize (default)** — 현재 설정을 실파일로 복사. `claude` 는 같은 설정으로 계속 동작; 다만 GitHub 자동 sync 만 멈춤.
   - **`p` Purge** — 심링크만 제거. `~/.claude/` 가 비고 `claude` 는 다음 실행 시 default 부터 시작.
2. **로컬 config repo clone 도 제거할까요?** 기본값 N.

그 다음 자동으로:

- `~/.zshrc`, `~/.bashrc` 에서 `# BEGIN cync` 블록 제거.
- 심링크 처리 (위 선택대로).
- `~/.claude/plugin-sync-state/`, `~/.claude/cync-last-sync` 제거.
- `~/.cync/` 제거.
- (선택했으면) 로컬 config repo clone 제거.

**GitHub 의 config repo 는 절대 안 건드림.** 다른 기기들은 그대로 동작. 같은 `curl | bash` 명령으로 언제든 재설치 가능.

## 필수 사전 요구사항

| 도구 | 왜 필요? | 없을 때 |
|------|---------|--------|
| `git` | cync 와 config repo clone/pull | 배포판별 install hint |
| `node` | Claude Code 자체가 Node.js 앱 | 배포판별 install hint |
| `claude` | cync 가 wrap 하는 대상 | 직접 install 명령 |
| `gh` | GitHub OAuth + repo CRUD | 배포판별 install hint (apt/dnf 의 repo 등록 파이프라인까지 포함) |
| `jq` *(선택)* | 플러그인 sync 가 `enabledPlugins` 파싱에 사용 | 경고만 — 다른 기능은 정상 |

이미 Claude Code 를 쓰는 사용자라면 `git`, `node`, `claude` 는 거의 확실히 있음. **새로 설치할 건 `gh` 하나** 가 보통.

설치 스크립트는 빠진 도구를 모두 모아서 한 번에 보고하므로, fresh 사내 서버도 한 번의 설치 라운드로 끝.

## License

MIT
