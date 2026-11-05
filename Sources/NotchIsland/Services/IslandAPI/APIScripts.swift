import Foundation

// The shell scripts the app writes into ~/.notchisland/ on every launch.

extension APIFiles {
    /// `notch` — the command-line front end for the Island API (zsh, ships with macOS).
    static let cliScript = #"""
    #!/bin/zsh
    # notch — show things on Notch Island from the terminal, scripts and Shortcuts.
    # Written by the Notch Island app on every launch; local edits are overwritten.
    emulate -L zsh

    URL="http://127.0.0.1:47290/v1"
    TOKEN_FILE="$HOME/.notchisland/token"

    # Errors go to stderr; when run from a hook (Claude Code, Copilot) nobody sees that,
    # so they're also kept in ~/.notchisland/notch.log.
    die() {
      print -u2 -- "notch: $*"
      [[ -t 2 ]] || print -r -- "$(date '+%F %T') notch: $*" >> ~/.notchisland/notch.log
      exit 1
    }

    usage() {
      cat <<'USAGE'
    notch — show alerts and progress on Notch Island

      notch "message" [--subtitle text] [--icon sf.symbol] [--color name] [--duration seconds]
      notch progress <id> "title" <value>     value: 0.4, 40 or 40%
      notch done <id> ["title"]
      notch clear                              remove all progress activities
      notch ping                               is Notch Island running?
      notch doctor                             why isn't something showing up?
      notch install-hook | uninstall-hook      alerts when long terminal commands finish

    Colors: green red blue orange yellow pink purple cyan teal indigo mint gray white
    Icons:  any SF Symbol name, e.g. hammer, checkmark.circle.fill, sparkles, house
    USAGE
    }

    post() {
      local endpoint=$1; shift
      [[ -r $TOKEN_FILE ]] || die "open Notch Island once first (no token yet)."
      local reply
      reply=$(curl --silent --max-time 2 -w '\n%{http_code}' \
                -H "Authorization: Bearer $(<$TOKEN_FILE)" "$@" "$URL/$endpoint") \
        || die "couldn't reach Notch Island. Is it running, with Island API turned on?"
      local code=${reply##*$'\n'}
      [[ $code == 200 ]] || die "${${reply%$'\n'*}:-HTTP $code}"
    }

    typeset -a opts
    parse_opts() {
      while (( $# )); do
        case $1 in
          --subtitle) opts+=(--data-urlencode "subtitle=$2"); shift 2 ;;
          --icon)     opts+=(--data-urlencode "icon=$2"); shift 2 ;;
          --color)    opts+=(--data-urlencode "color=$2"); shift 2 ;;
          --duration) opts+=(--data-urlencode "duration=$2"); shift 2 ;;
          --badge)    opts+=(--data-urlencode "badge=$2"); shift 2 ;;
          *) die "unknown option: $1 (try: notch --help)" ;;
        esac
      done
    }

    case ${1:-} in
      ""|-h|--help|help)
        usage ;;
      ping)
        curl --silent --max-time 1 "$URL/ping" >/dev/null \
          && print "Notch Island is listening ✓" \
          || die "Notch Island isn't reachable (not running, or Island API is off)." ;;
      progress)
        shift
        (( $# >= 3 )) || die 'usage: notch progress <id> "title" <value>'
        id=$1; title=$2; value=$3; shift 3
        parse_opts "$@"
        post progress --data-urlencode "id=$id" --data-urlencode "title=$title" --data-urlencode "value=$value" $opts ;;
      done)
        shift
        (( $# >= 1 )) || die 'usage: notch done <id> ["title"]'
        id=$1; shift
        title=""
        if (( $# )) && [[ $1 != --* ]]; then title=$1; shift; fi
        parse_opts "$@"
        post done --data-urlencode "id=$id" --data-urlencode "title=$title" $opts ;;
      clear)
        post clear --data "all=1" ;;
      agent)
        # Called by Claude Code / Copilot hooks with the event as JSON on stdin.
        # Read it now (fast), then parse and send in the background so the agent never waits.
        agent=${2:-agent}; event=${3:-}
        json=$(cat)
        {
          # agent.js (JavaScript for Automation, built into macOS) pulls out a few small
          # fields — hook input can hold whole files, and may contain nulls.
          fields=("${(@f)$(print -r -- "$json" | osascript -l JavaScript ~/.notchisland/agent.js 2>>~/.notchisland/notch.log)}")
          f() { local v=${fields[$1]-}; print -r -- "${v#|}" }
          [[ -z $event ]] && event=$(f 1)
          if [[ -z $event ]]; then
            print -r -- "$(date '+%F %T') notch agent $agent: couldn't read the hook event" >> ~/.notchisland/notch.log
            exit 0
          fi
          cwd=$(f 3); [[ -z $cwd ]] && cwd=$PWD
          # One line per hook call, so `notch doctor` can tell whether the agent runs the hooks.
          log=~/.notchisland/agent.log
          print -r -- "$(date '+%F %T') $agent $event $(f 4)" >> $log
          (( $(wc -l < $log) > 400 )) && { tail -n 200 $log > $log.tmp && mv $log.tmp $log }
          post agent --data-urlencode "agent=$agent" --data-urlencode "event=$event" \
            --data-urlencode "session=$(f 2)" --data-urlencode "cwd=$cwd" \
            --data-urlencode "tool=$(f 4)" --data-urlencode "target=$(f 5)" \
            --data-urlencode "prompt=$(f 6)" --data-urlencode "message=$(f 7)" \
            --data-urlencode "transcript=$(f 8)" --data-urlencode "host=${__CFBundleIdentifier:-}"
        } </dev/null &>/dev/null &!
        ;;
      doctor)
        # Why isn't the island showing anything? Checks each link in the chain.
        ok() { print "  ✓ $*" }; bad() { print "  ✗ $*" }
        print "Notch Island check"
        curl --silent --max-time 1 "$URL/ping" >/dev/null && ok "app is running and listening" \
          || bad "app not reachable — open Notch Island and turn on Terminal & Island API"
        [[ -r $TOKEN_FILE ]] && ok "token found" || bad "no token — open the app once"
        if grep -q 'notch agent claude' ~/.claude/settings.json 2>/dev/null; then
          ok "Claude Code hooks installed (restart running Claude sessions after changes)"
        else
          bad "Claude Code hooks missing — Settings ▸ Terminal ▸ Connect Claude Code"
        fi
        managed="/Library/Application Support/ClaudeCode/managed-settings.json"
        if [[ -f $managed ]] && grep -Eq '"(allowManagedHooksOnly|disableAllHooks)"[[:space:]]*:[[:space:]]*true' "$managed"; then
          bad "your organisation's Claude Code policy blocks personal hooks ($managed)"
        fi
        # Shell hook (long terminal commands)
        if grep -q '.notchisland/hook.zsh' ~/.zshrc 2>/dev/null; then
          min=$(sed -n 's/^NOTCH_MIN_SECONDS=//p' ~/.notchisland/config.zsh 2>/dev/null)
          ok "shell hook is in ~/.zshrc — alerts for commands that take ${min:-30}s or longer"
          print "    Tabs opened before the app was last updated run the old hook: open a new tab or run  exec zsh"
        else
          bad "shell hook not installed — Settings ▸ Terminal ▸ Long-running command alerts"
        fi
        if [[ -r $TOKEN_FILE ]]; then
          reply=$(curl --silent --max-time 2 -H "Authorization: Bearer $(<$TOKEN_FILE)" \
                    --data-urlencode "cmd=notch doctor (test)" --data "seconds=20" --data "exit=0" --data "dir=test" \
                    "$URL/command-finished")
          case $reply in
            *ignored*) bad "the app skipped a test alert: ${reply}" ;;
            *error*) bad "test alert failed: ${reply}" ;;
            *true*) ok "test alert sent — look at the notch" ;;
            *) bad "test alert failed: ${reply:-no reply}" ;;
          esac
        fi
        if [[ -s ~/.notchisland/agent.log ]]; then
          ok "agents have called the island — last: $(tail -1 ~/.notchisland/agent.log)"
        else
          bad "no agent has run the hooks yet — restart Claude Code (type /hooks inside it to check)"
        fi
        [[ -f ~/.notchisland/agent.js ]] && ok "agent.js present" || bad "agent.js missing — restart the app"
        result=$(print -r -- '{"hook_event_name":"Stop","session_id":null,"cwd":"/tmp"}' | osascript -l JavaScript ~/.notchisland/agent.js 2>&1 | head -1)
        [[ $result == '|Stop' ]] && ok "hook input parsing works" || bad "hook input parsing failed: $result"
        if [[ -s ~/.notchisland/notch.log ]]; then
          print "Recent errors (~/.notchisland/notch.log):"
          tail -5 ~/.notchisland/notch.log | sed 's/^/    /'
        fi ;;
      install-hook)
        line='[ -f ~/.notchisland/hook.zsh ] && source ~/.notchisland/hook.zsh  # Notch Island'
        touch ~/.zshrc
        if grep -q '.notchisland/hook.zsh' ~/.zshrc; then
          print "Already installed ✓"
        else
          print -r -- "" >> ~/.zshrc
          print -r -- "$line" >> ~/.zshrc
          print "Installed ✓  Open a new terminal tab (or run: source ~/.zshrc)."
        fi ;;
      uninstall-hook)
        [[ -f ~/.zshrc ]] && sed -i '' '/\.notchisland\/hook\.zsh/d' ~/.zshrc
        print "Removed ✓  Open a new terminal tab." ;;
      -*)
        die "unknown option: $1 (try: notch --help)" ;;
      *)
        title=$1; shift
        parse_opts "$@"
        post show --data-urlencode "title=$title" $opts ;;
    esac
    """#

    /// agent.js — reads a Claude Code / Copilot hook event (JSON on stdin) and prints the
    /// fields `notch agent` needs, one per line, each prefixed with "|" so empty ones survive:
    /// event, session, cwd, tool, target, prompt, message, transcript.
    static let agentScript = #"""
    ObjC.import('Foundation');
    function run() {
      var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
      var text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js || '{}';
      var j = {};
      try { j = JSON.parse(text) || {}; } catch (e) {}
      var input = j.tool_input || {};
      if (typeof j.toolArgs === 'string') {
        try { input = JSON.parse(j.toolArgs) || {}; } catch (e) {}
      } else if (j.toolArgs) {
        input = j.toolArgs;
      }
      var target = '';
      ['file_path', 'notebook_path', 'path', 'command', 'pattern', 'url', 'query', 'description'].some(function (k) {
        if (input && input[k]) { target = String(input[k]); return true; }
        return false;
      });
      var out = [j.hook_event_name, j.session_id, j.cwd, j.tool_name || j.toolName, target,
                 j.prompt, j.message, j.transcript_path];
      return out.map(function (v) {
        return '|' + String(v == null ? '' : v).replace(/[\r\n]+/g, ' ').slice(0, 400);
      }).join('\n');
    }
    """#

    /// The zsh hook: alerts when a command that took a while finishes.
    static let hookScript = #"""
    # ~/.notchisland/hook.zsh — tells Notch Island when a long terminal command finishes.
    # Loaded by one line in ~/.zshrc. Written by the app on every launch; edits are overwritten.

    # Load only once per shell (re-running `source ~/.zshrc` won't add duplicates).
    [[ -n $_NOTCH_HOOK_LOADED ]] && return
    _NOTCH_HOOK_LOADED=1

    # Make the `notch` command available in this shell.
    path=(~/.notchisland/bin $path)

    # Settings (Settings ▸ Terminal in the app writes config.zsh; re-read after every
    # command, so changes apply to terminal tabs that are already open).
    NOTCH_MIN_SECONDS=30
    NOTCH_SHOW_COMMAND=1
    NOTCH_IGNORE=(vim nvim vi nano emacs less more man top htop btop ssh tmux screen watch tail claude copilot)
    [[ -f ~/.notchisland/config.zsh ]] && source ~/.notchisland/config.zsh

    _NOTCH_URL="http://127.0.0.1:47290/v1/command-finished"

    zmodload zsh/datetime    # $EPOCHREALTIME: precise clock, no subprocess

    # Before each command: remember what and when.
    _notch_preexec() {
      _notch_cmd=$1
      _notch_start=$EPOCHREALTIME
      # Tell the island which terminal this runs in, so it can say when the command
      # waits for your input (a password, [y/N]…). Background, so nothing waits.
      [[ $1 == ' '* ]] && return                                   # leading space = private
      local program=${${(z)1}[1]}
      (( ${NOTCH_IGNORE[(Ie)$program]} )) && return                # interactive tool
      [[ -r ~/.notchisland/token && -n ${TTY:-} ]] || return
      local cmd=${1[1,80]}
      (( NOTCH_SHOW_COMMAND )) || cmd="A command"
      {
        curl --silent --max-time 1 \
             -H "Authorization: Bearer $(<~/.notchisland/token)" \
             --data-urlencode "cmd=$cmd" \
             --data-urlencode "tty=$TTY" \
             --data-urlencode "shell=$$" \
             --data-urlencode "host=${__CFBundleIdentifier:-}" \
             "${_NOTCH_URL%/command-finished}/command-started"
      } &>/dev/null &!
    }

    # After each command, just before the prompt is drawn.
    _notch_precmd() {
      local exit_code=$?                     # must be first: anything else overwrites $?
      [[ -z $_notch_start ]] && return       # empty Enter, nothing ran
      [[ -f ~/.notchisland/config.zsh ]] && source ~/.notchisland/config.zsh   # latest settings

      local elapsed=$(( EPOCHREALTIME - _notch_start ))
      local cmd=$_notch_cmd
      unset _notch_start _notch_cmd

      (( elapsed < NOTCH_MIN_SECONDS )) && return               # too quick
      (( exit_code == 130 )) && return                          # you pressed Ctrl+C
      [[ $cmd == ' '* ]] && return                              # leading space = private
      local program=${${(z)cmd}[1]}
      (( ${NOTCH_IGNORE[(Ie)$program]} )) && return             # interactive tool
      [[ -r ~/.notchisland/token ]] || return

      (( NOTCH_SHOW_COMMAND )) || cmd="Command finished"
      cmd=${cmd[1,80]}

      # Tell the app in the background; the prompt never waits.
      {
        curl --silent --max-time 1 \
             -H "Authorization: Bearer $(<~/.notchisland/token)" \
             --data-urlencode "cmd=$cmd" \
             --data-urlencode "seconds=${elapsed%.*}" \
             --data-urlencode "exit=$exit_code" \
             --data-urlencode "dir=${PWD:t}" \
             "$_NOTCH_URL"
      } &>/dev/null &!
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _notch_preexec
    add-zsh-hook precmd  _notch_precmd
    """#
}
