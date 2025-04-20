```
cat > ~/.local/share/applications/start_vm_myvm.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=myvm
Comment=Start My Virtual Machine
Exec=/home/<user>/Devops/jgy/my-scripts/Linux/virt_manager_shortcut/start_vm.sh myvm
Icon=/home/<user>/Pictures/Icons/myvm.png
Terminal=false
EOF
```
