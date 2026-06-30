# Records scripts/demo.sh (make demo) as the README's wedge-recovery GIF.
# Requires VHS (https://github.com/charmbracelet/vhs):
#
#   brew install vhs
#   swift build                       # so the GIF shows the demo, not the compile
#   vhs assets/wedge-recovery.tape    # writes assets/wedge-recovery.gif
#
# Tweak Width/Height/FontSize to taste; raise Sleep if the demo runs long on your
# machine, or add `Set PlaybackSpeed 1.5` to tighten a long recording.
Output assets/wedge-recovery.gif

Set Shell bash
Set FontSize 14
Set Width 1080
Set Height 800
Set Padding 18

Type "make demo" Enter
Sleep 35s
