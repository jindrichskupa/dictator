# Source of truth for Formula/dictator.rb in jindrichskupa/homebrew-tap.
# The `tap` job in .github/workflows/release.yml copies it there on every tag,
# rewriting url and sha256. Edit it here, not in the tap.
#
# A formula rather than a cask — the tap's franta is a cask because it ships a
# prebuilt binary; dictator is shell source, which is what formulae are for.
class Dictator < Formula
  desc "One registry of Claude Code sessions across every repository"
  homepage "https://github.com/jindrichskupa/dictator"
  url "https://github.com/jindrichskupa/dictator/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/jindrichskupa/dictator.git", branch: "master"

  depends_on "fzf"
  depends_on "jq"
  depends_on "tmux"

  def install
    # The plugin locates itself from its own path, so a plain copy is enough.
    prefix.install "dictator.plugin.zsh", "lib", "functions", "hooks", "tmux"
    zsh_completion.install "functions/_dict"
    doc.install "README.md"
  end

  def caveats
    <<~EOS
      Add to your ~/.zshrc:

        source #{opt_prefix}/dictator.plugin.zsh

      Then register the Claude Code hooks by merging this into the "hooks"
      object of ~/.claude/settings.json (add to it, do not replace it):

        "UserPromptSubmit": [{ "hooks": [{ "type": "command",
          "command": "#{opt_prefix}/hooks/dict-status.sh running" }] }],
        "Notification":     [{ "matcher": "permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog",
          "hooks": [{ "type": "command",
          "command": "#{opt_prefix}/hooks/dict-status.sh waiting" }] }],
        "Stop":             [{ "hooks": [{ "type": "command",
          "command": "#{opt_prefix}/hooks/dict-status.sh done" }] }],
        "SessionEnd":       [{ "hooks": [{ "type": "command",
          "command": "#{opt_prefix}/hooks/dict-status.sh ended" }] }]

      Without the hooks everything works except the state column.
    EOS
  end

  test do
    # The install prefix is read-only, so point the state directory at the
    # sandbox: dictator generates its tmux config there at first use.
    ENV["DICTATOR_STATE"] = testpath/"state"
    system "zsh", "-n", "#{prefix}/dictator.plugin.zsh"
    assert_match "dictator", shell_output(
      "zsh -f -c 'source #{prefix}/dictator.plugin.zsh; dict help'"
    )
    assert_match "no sessions yet", shell_output(
      "zsh -f -c 'source #{prefix}/dictator.plugin.zsh; dict ls'"
    )
    # `dict ls` returns before touching tmux when the registry is empty, so
    # generation is exercised directly.
    system "zsh", "-f", "-c",
           "source #{prefix}/dictator.plugin.zsh; _dict_gen_conf"
    assert_predicate testpath/"state/tmux.conf", :exist?,
                     "the tmux config should be generated into DICTATOR_STATE"
    refute_match "@DICTATOR_HOME@", (testpath/"state/tmux.conf").read
  end
end
