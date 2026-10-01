# Ansible Configuration Notes

## `ansible.cfg`

- Specify the exact inventory filename using the `inventory` parameter.
  - In this setup, the inventory file is named `hosts` (created inside the `ansible` directory), so:
    
    inventory=hosts
    
- Disable SSH host key checking to avoid interactive prompts:
  
  host_key_checking = False


### `[privilege_escalation]`

Since `become_user` is `root`, every task executes as root on the managed nodes.


[privilege_escalation]
become_method=sudo
become=yes
---

## Inventory File (`hosts`)

### Group Definition

Define a group name and list the servers under it. In this case, the group is `rac_nodes`:


[rac_nodes]
server1
server2
server3


Do **not** store plaintext credentials (`ansible_ssh_user` / `ansible_ssh_pass`) in `[all:vars]` in the inventory for production use. Use `ansible-vault` instead (see below).

---

## Credentials with `ansible-vault`

### Directory Structure

`group_vars/` must sit **next to the inventory file** (`hosts`), 


ansible/
├── ansible.cfg
├── hosts               ← inventory file
└── group_vars/         ← must be next to 'hosts'
    └── all/             (or a specific group name, e.g. rac_nodes)
        ├── vars.yml      # plaintext, references vault vars
        └── vault.yml     # encrypted secrets


### Step 1 — Create the encrypted vault file
ansible-vault create group_vars/all/vault.yml

Add inside (each var on its own line):
```yaml
vault_ansible_ssh_user: your_user
vault_ansible_ssh_pass: your_password
```

### Step 2 — Reference vault vars in plaintext `vars.yml`

```yaml
---
ansible_user: "{{ vault_ansible_ssh_user }}"
ansible_password: "{{ vault_ansible_ssh_pass }}"
```

### Step 3 — Run with vault password

# Interactive prompt
ansible-playbook -i hosts master.yml --ask-vault-pass

# Or via password file (for automation/CI)
echo "your-vault-password" > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
ansible-playbook -i hosts master.yml --vault-password-file ~/.vault_pass.txt


### Verification
# Confirm vault decrypts correctly
ansible-vault view group_vars/all/vault.yml --ask-vault-pass

# Confirm variable resolves for the target group
ansible -i hosts rac_nodes -m debug -a "var=ansible_user" --ask-vault-pass

# Test connectivity
ansible -i hosts rac_nodes -m ping --ask-vault-pass

