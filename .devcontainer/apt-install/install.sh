set -e  # Exit on error
# Install basic development dependencies for Ruby & JRuby projects
apt-get update -y
apt-get install -y direnv default-jdk git zlib1g-dev build-essential libssl-dev libreadline-dev libyaml-dev libxml2-dev libxslt1-dev libcurl4-openssl-dev software-properties-common libffi-dev
echo "Basic apt packages installed. Tree-sitter will be set up after workspace mount."
# Adds the direnv setup script to ~/.bashrc file (at the end)
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
