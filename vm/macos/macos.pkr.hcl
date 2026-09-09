# Adapted from https://github.com/Parallels/packer-examples/blob/main/macos/provisioner_tahoe_26.pkr.hcl
# MIT License
# Copyright (c) 2021 Carlos Lapao
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

packer {
  required_plugins {
    parallels = {
      source  = "github.com/Pr0Ger/parallels"
      version = "= 1.2.9-dev"
    }
  }
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type    = number
  default = 131072
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

variable "output_directory" {
  type = string
}

variable "source_archive" {
  type = string
}

variable "public_key_file" {
  type = string
}

source "parallels-ipsw" "macos" {
  output_directory = var.output_directory
  startup_view     = "window"
  ocr_library      = "vision"
  disk_size        = var.disk_size
  ssh_timeout      = "30m"
  shutdown_timeout = "5m"

  boot_screen_config {
    boot_command     = ["<wait1s><enter>"]
    screen_name      = "Empty"
    matching_strings = []
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<wait1s><enter>"]
    screen_name      = "GetStarted"
    matching_strings = ["Get Started"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<wait1s><enter>"]
    screen_name      = "GetStarted1"
    matching_strings = ["hola"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<wait1s><enter>"]
    screen_name      = "GetStarted2"
    matching_strings = ["hallo"]
    execute_only_once = true
  }


  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "Language"
    matching_strings = ["English", "Language", "Australia", "India"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "Country"
    matching_strings = ["Select Your Country or Region"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><tab><spacebar><tab><tab><spacebar>"]
    screen_name      = "Data"
    matching_strings = ["transfer", "information"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "SpokenLanguages"
    matching_strings = ["Written and Spoken Languages"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "Accessibility"
    matching_strings = ["Accessibility", "Vision", "Hearing", "Motor", "Cognitive"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "DataAndPrivacy"
    matching_strings = ["Data", "Privacy", "This icon appears"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><tab><tab><tab><tab>nixvm<tab>${var.ssh_password}<tab>${var.ssh_password}<tab>nixvm<tab><tab><tab><tab><spacebar>"]
    screen_name      = "CreateAccount"
    matching_strings = ["Create a Mac Account", "The password you create here"]
  }

  boot_screen_config {
    boot_command     = ["<leftCtrlOn><f7><leftCtrlOff><wait2s><leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "SignInToApple"
    matching_strings = ["Sign In to Your Apple Account", "Sign in to use iCloud"]
  }

  boot_screen_config {
    boot_command     = ["<tab><spacebar>"]
    screen_name      = "SignInWithApplePopup"
    matching_strings = ["Are you sure you want to skip", "signing in with an Apple ID?"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><spacebar><wait2s><tab><spacebar>"]
    screen_name      = "TermsAndConditionsUK"
    matching_strings = ["Terms and Conditions", "macOS Software Licence Agreement", "Tahoe 26"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><spacebar><wait2s><tab><spacebar>"]
    screen_name      = "TermsAndConditionsUS"
    matching_strings = ["Terms and Conditions", "macOS Software License Agreement", "Tahoe 26"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar><wait2s><tab><spacebar>"]
    screen_name      = "LocationServices"
    matching_strings = ["Enable Location Services", "About Location Services"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "TimeZone"
    matching_strings = ["Select your Time Zone"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "Analytics"
    matching_strings = ["Share Mac Analytics with Apple"]
  }

  boot_screen_config {
    boot_command     = ["<leftShiftOn><tab><leftShiftOff><spacebar>"]
    screen_name      = "ScreenTime"
    matching_strings = ["Screen Time", "Get insights about your"]
  }

  boot_screen_config {
    boot_command     = ["<tab><spacebar><tab><tab><tab><spacebar>"]
    screen_name      = "Siri"
    matching_strings = ["Siri", "Siri helps you get things done"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><spacebar><wait2s><tab><spacebar>"]
    screen_name      = "FileVault"
    matching_strings = ["Your Mac is Ready for FileVault", "encrypting your data", "Not Now"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><tab><tab><spacebar>"]
    screen_name      = "Looks"
    matching_strings = ["Choose your look", "Select an appearance"]
  }

  boot_screen_config {
    boot_command     = ["<tab><tab><tab><spacebar>"]
    screen_name      = "UpdateMacAutomatically"
    matching_strings = ["Update Mac Automatically", "Software Update settings", "Only Download Automatically"]
  }

  boot_screen_config {
    boot_command     = [
      "<leftShiftOn><leftSuperOn>G<leftSuperOff><leftShiftOff>/Applications/Utilities/Terminal.app<enter><leftSuperOn>o<leftSuperOff>",
    ]
    screen_name      = "Desktop"
    matching_strings = ["Finder", "Go"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command = [
      "<leftCtrlOn>c<leftCtrlOff><enter><wait2s>",
      "printf '%s\\n' '${var.ssh_password}' | sudo -S /bin/sh -c 'printf \"%s\\n\" \"nixvm ALL=(ALL) NOPASSWD: ALL\" > /private/etc/sudoers.d/nixvm; chmod 440 /private/etc/sudoers.d/nixvm'<enter><wait3s>",
      "sudo scutil --set HostName dotfiles-vm; sudo scutil --set LocalHostName dotfiles-vm; sudo scutil --set ComputerName dotfiles-vm<enter><wait2s>",
      "sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist<enter><wait2s>",

      "sudo launchctl stop com.parallels.desktop.mobile.launchdaemon<enter><wait1s>",
      "sudo launchctl start com.parallels.desktop.mobile.launchdaemon<enter><wait1s>",

      "sudo reboot<enter>"
    ]
    screen_name      = "TerminalSetup"
    matching_strings = ["nixvm", "Last login", "%"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<wait5s>${var.ssh_password}<enter>"]
    screen_name      = "PostRebootLogin"
    matching_strings = ["nixvm", "Enter Password"]
    execute_only_once = true
  }


  boot_screen_config {
    boot_command = [
      "<leftCtrlOn>c<leftCtrlOff><enter><wait2s>",
      "sudo launchctl stop com.parallels.desktop.mobile.launchdaemon; sudo launchctl start com.parallels.desktop.mobile.launchdaemon<enter><wait5s>",
      "sudo '/Volumes/Parallels Tools/Install.app/Contents/MacOS/PTIAgent' --install<enter>"
    ]
    screen_name      = "TerminalTools"
    matching_strings = ["Restored", "nixvm"]
    execute_only_once = true
  }

  boot_screen_config {
    boot_command     = ["<spacebar><wait2s><enter>"]
    screen_name      = "PDSuccess"
    matching_strings = ["Installed successfully", "Restart"]
    is_last_screen   = true
  }

  boot_screen_config {
    boot_command     = ["<wait3s><spacebar>"]
    screen_name      = "WelcomeScreen"
    matching_strings = ["Welcome to mac", "Continue"]
    execute_only_once = true
  }


  boot_wait        = "1s"
  shutdown_command = "sudo shutdown -h now"
  ipsw_url         = "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-37622/CE01FAB2-7F26-48EE-AEE4-5E57A7F6D8BB/UniversalMac_26.0_25A354_Restore.ipsw"
  ipsw_checksum    = "sha256:ec98309d97fdc399f7baa5f1e11d121e8ffda798d885219fee9c4c94b4f219d6"
  ssh_username     = "nixvm"
  ssh_password     = var.ssh_password
  vm_name          = "dotfiles-vm"
  cpus             = var.cpus
  memory           = var.memory
}

build {
  sources = ["source.parallels-ipsw.macos"]

  provisioner "shell" {
    inline = ["mkdir -p /Users/nixvm/.ssh /Users/nixvm/dotfiles"]
  }

  provisioner "file" {
    source      = var.public_key_file
    destination = "/Users/nixvm/.ssh/authorized_keys"
  }

  provisioner "file" {
    source      = var.source_archive
    destination = "/Users/nixvm/dotfiles-source.tar"
  }

  provisioner "shell" {
    inline = [
      "chmod 700 /Users/nixvm/.ssh; chmod 600 /Users/nixvm/.ssh/authorized_keys",
      "tar -xf /Users/nixvm/dotfiles-source.tar -C /Users/nixvm/dotfiles",
      "/bin/bash /Users/nixvm/dotfiles/vm/macos/provision.sh install"
    ]
  }
}
