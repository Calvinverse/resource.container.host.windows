# frozen_string_literal: true

#
# Cookbook Name:: resource_container_host_windows
# Recipe:: provisioning
#
# Copyright 2017, P. van der Velde
#

service_name = node['service']['provisioning']
win_service_name = 'provisioning_service'

#
# DIRECTORIES
#

log_directory = node['paths']['log']
directory log_directory do
  action :create
  rights :read, 'Everyone', applies_to_children: true
  rights :modify, 'Administrators', applies_to_children: true
end

provisioning_logs_directory = node['paths']['provisioning_logs']
directory provisioning_logs_directory do
  action :create
  rights :modify, 'Administrators', applies_to_children: true, applies_to_self: false
end

ops_base_directory = node['paths']['ops_base']
directory ops_base_directory do
  action :create
  rights :read, 'Everyone', applies_to_children: true
  rights :modify, 'Administrators', applies_to_children: true
end

provisioning_base_directory = node['paths']['provisioning_base']
directory provisioning_base_directory do
  action :create
  rights :read, 'Everyone', applies_to_children: true
  rights :modify, 'Administrators', applies_to_children: true
end

provisioning_service_directory = node['paths']['provisioning_service']
directory provisioning_service_directory do
  action :create
end

#
# CONFIGURE THE PROVISIONING SCRIPT
#

provisioning_script = 'Initialize-Resource.ps1'
cookbook_file "#{provisioning_base_directory}\\#{provisioning_script}" do
  action :create
  source provisioning_script
end

#
# WINDOWS SERVICE
#

cookbook_file "#{provisioning_service_directory}\\#{win_service_name}.exe" do
  source 'WinSW.NET4.exe'
  action :create
end

file "#{provisioning_service_directory}\\#{win_service_name}.exe.config" do
  content <<~XML
    <configuration>
        <runtime>
            <generatePublisherEvidence enabled="false"/>
        </runtime>
    </configuration>
  XML
  action :create
end

file "#{provisioning_service_directory}\\#{win_service_name}.xml" do
  content <<~XML
    <?xml version="1.0"?>
    <!--
        The MIT License Copyright (c) 2004-2009, Sun Microsystems, Inc., Kohsuke Kawaguchi Permission is hereby granted, free of charge, to any person obtaining a
        copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
        subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
        PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
        OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    -->

    <service>
        <id>#{service_name}</id>
        <name>#{service_name}</name>
        <description>This service executes the environment provisioning for the current resource.</description>

        <executable>powershell.exe</executable>
        <arguments>-NonInteractive -NoProfile -NoLogo -ExecutionPolicy RemoteSigned -File #{provisioning_base_directory}\\#{provisioning_script}</arguments>

        <logpath>#{provisioning_logs_directory}</logpath>
        <log mode="roll-by-size">
            <sizeThreshold>10240</sizeThreshold>
            <keepFiles>8</keepFiles>
        </log>
        <onfailure action="none"/>
    </service>
  XML
  action :create
end

# Create the event log source for the nomad service. We'll create it now because the service runs as a normal user
# and is as such not allowed to create eventlog sources
registry_key "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\services\\eventlog\\Application\\#{service_name}" do
  action :create
  values [{
    data: 'c:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\EventLogMessages.dll',
    name: 'EventMessageFile',
    type: :string
  }]
end

powershell_script 'provisioning_as_service' do
  code <<~POWERSHELL
    $ErrorActionPreference = 'Stop'

    # Using the LocalSystem account so that the scripts that we run have access to everything:
    # https://msdn.microsoft.com/en-us/library/windows/desktop/ms684190%28v=vs.85%29.aspx
    #
    # Provide no credential to run as the LocalSystem account:
    # http://stackoverflow.com/questions/14708825/how-to-create-a-windows-service-in-powershell-for-network-service-account
    $service = Get-Service -Name '#{service_name}' -ErrorAction SilentlyContinue
    if ($service -eq $null)
    {
        New-Service `
            -Name '#{service_name}' `
            -BinaryPathName '#{provisioning_service_directory}\\#{win_service_name}.exe' `
            -DisplayName '#{service_name}' `
            -StartupType Automatic
    }

    # Set the service to restart if it fails
    sc.exe failure #{service_name} reset=86400 actions=restart/5000
  POWERSHELL
end
