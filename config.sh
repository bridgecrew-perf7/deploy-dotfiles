# Sourced by deploy-dotfiles.sh
# User created file to override program defaults.

# How to identify this computer. E.g., which config options to load? Should be a
# descriptive 'class' that accepts a common config. E.g., "macos" or "ubuntu".
# Or maybe "personal" vs. "work". Imacts which configuration variables are
# sourced from the config/files/$filetype/{options,additions}
class=

# Methodology by which to 'deploy' the dotfiles to their respective location.
#  slink :: `ln -s` (symlink)
#  hlink :: `ln` (hard link)
#  copy  :: `cp`
deploy_mode='link'

# If there is an existing file at the $destination, should (and if so, how) the
# existing file be backed up?
#  dir  :: `mv` the file to config/backup/$filename (removing leading '.')
#  bak  :: `mv` in place, with a '.bak' extension
#  none :: No backup performed, file is overwritten if exists
backup_mode='dir'
