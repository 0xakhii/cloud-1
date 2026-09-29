# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "cloud-1"

  # Private network — access all services at this IP
  config.vm.network "private_network", ip: "192.168.56.10"

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "cloud-1"
    vb.memory = "2048"
    vb.cpus   = 2
  end

  # Provision with Ansible from host
  config.vm.provision "ansible" do |ansible|
    ansible.playbook = "playbook.yml"
    ansible.groups   = { "web" => ["default"] }
    ansible.extra_vars = { server_name: "192.168.56.10" }
    if File.exist?(".vault_pass")
      ansible.vault_password_file = ".vault_pass"
    end
  end
end