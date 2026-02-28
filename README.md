# Selkie Package Repository

This branch hosts APT and DNF package repositories for [Selkie](https://github.com/aaddrick/selkie).

## APT (Debian/Ubuntu)

```bash
curl -fsSL https://aaddrick.github.io/selkie/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/selkie.gpg
echo "deb [signed-by=/usr/share/keyrings/selkie.gpg arch=amd64,arm64] https://aaddrick.github.io/selkie stable main" | sudo tee /etc/apt/sources.list.d/selkie.list
sudo apt update && sudo apt install selkie
```

## DNF (Fedora/RHEL)

```bash
sudo curl -fsSL https://aaddrick.github.io/selkie/rpm/selkie.repo -o /etc/yum.repos.d/selkie.repo
sudo dnf install selkie
```
