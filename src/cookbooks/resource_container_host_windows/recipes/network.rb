# frozen_string_literal: true

#
# Cookbook Name:: resource_container_host_windows
# Recipe:: network
#
# Copyright 2017, P. van der Velde
#

#
# USER
#

service_username = node['service']['unbound_user_name']
service_password = node['service']['unbound_user_password']

# Configure the service user under which consul will be run
# Make sure that the user password doesn't expire. The password is a random GUID, so it is unlikely that
# it will ever be guessed. And the user is a normal user who can't do anything so we don't really care about it
powershell_script 'unbound_user_with_password_that_does_not_expire' do
  code <<~POWERSHELL
    $user = '#{service_username}'
    $password = '#{service_password}'
    $ObjOU = [ADSI]"WinNT://$env:ComputerName"
    $objUser = $objOU.Create("User", $user)
    $objUser.setpassword($password)
    $objUser.UserFlags = 64 + 65536 # ADS_UF_PASSWD_CANT_CHANGE + ADS_UF_DONT_EXPIRE_PASSWD
    $objUser.SetInfo()
  POWERSHELL
end

# Grant the user the LogOnAsService permission. Following this anwer on SO: http://stackoverflow.com/a/21235462/539846
# With some additional bug fixes to get the correct line from the export file and to put the correct text in the import file
powershell_script 'unbound_user_grant_service_logon_rights' do
  code <<~POWERSHELL
    $ErrorActionPreference = 'Stop'

    $userName = '#{service_username}'

    $tempPath = "c:\\temp"
    if (-not (Test-Path $tempPath))
    {
        New-Item -Path $tempPath -ItemType Directory | Out-Null
    }

    $import = Join-Path -Path $tempPath -ChildPath "import.inf"
    if(Test-Path $import)
    {
        Remove-Item -Path $import -Force
    }

    $export = Join-Path -Path $tempPath -ChildPath "export.inf"
    if(Test-Path $export)
    {
        Remove-Item -Path $export -Force
    }

    $secedt = Join-Path -Path $tempPath -ChildPath "secedt.sdb"
    if(Test-Path $secedt)
    {
        Remove-Item -Path $secedt -Force
    }

    $sid = ((New-Object System.Security.Principal.NTAccount($userName)).Translate([System.Security.Principal.SecurityIdentifier])).Value

    secedit /export /cfg $export
    $line = (Select-String $export -Pattern "SeServiceLogonRight").Line
    $sids = $line.Substring($line.IndexOf('=') + 1).Trim()

    if (-not ($sids.Contains($sid)))
    {
        Write-Host ("Granting SeServiceLogonRight to user account: {0} on host: {1}." -f $userName, $computerName)
        $lines = @(
                "[Unicode]",
                "Unicode=yes",
                "[System Access]",
                "[Event Audit]",
                "[Registry Values]",
                "[Version]",
                "signature=`"`$CHICAGO$`"",
                "Revision=1",
                "[Profile Description]",
                "Description=GrantLogOnAsAService security template",
                "[Privilege Rights]",
                "SeServiceLogonRight = $sids,*$sid"
            )
        foreach ($line in $lines)
        {
            Add-Content $import $line
        }

        secedit /import /db $secedt /cfg $import
        secedit /configure /db $secedt
        gpupdate /force
    }
    else
    {
        Write-Host ("User account: {0} on host: {1} already has SeServiceLogonRight." -f $userName, $computerName)
    }
  POWERSHELL
end

#
# DIRECTORIES
#

unbound_logs_directory = node['paths']['unbound_logs']
directory unbound_logs_directory do
  action :create
  rights :modify, service_username, applies_to_children: true, applies_to_self: false
end

unbound_base_directory = node['paths']['unbound_base']
directory unbound_base_directory do
  action :create
end

unbound_config_directory = node['paths']['unbound_config']
directory unbound_config_directory do
  action :create
end

#
# INSTALL UNBOUND
#

cookbook_file "#{unbound_base_directory}\\unbound.exe" do
  action :create
  source 'unbound/unbound.exe'
end

#
# CONFIGURATION
#

unbound_config_file = node['file_name']['unbound_config_file']
file "#{unbound_base_directory}\\#{unbound_config_file}" do
  action :create
  content <<~CONF
    #
    # See unbound.conf(5) man page, version 1.6.3.
    #

    # Use this to include other text into the file.
    include: "#{unbound_config_directory}\\unbound_zones.conf"

    # The server clause sets the main parameters.
    server:
        # whitespace is not necessary, but looks cleaner.

        # verbosity number, 0 is least verbose. 1 is default, 4 is maximum.
        verbosity: 1

        # specify the interfaces to answer queries from by ip-address.
        # The default is to listen to localhost (127.0.0.1 and ::1).
        # specify 0.0.0.0 and ::0 to bind to all available interfaces.
        # specify every interface[@port] on a new 'interface:' labelled line.
        # The listen interfaces are not changed on reload, only on restart.
        interface: 127.0.0.1

        # port to answer queries from
        port: 53

        # specify the interfaces to send outgoing queries to authoritative
        # server from by ip-address. If none, the default (all) interface
        # is used. Specify every interface on a 'outgoing-interface:' line.
        # outgoing-interface: 192.0.2.153

        # deny unbound the use this of port number or port range for
        # making outgoing queries, using an outgoing interface.
        # Use this to make sure unbound does not grab a UDP port that some
        # other server on this computer needs. The default is to avoid
        # IANA-assigned port numbers.
        # If multiple outgoing-port-permit and outgoing-port-avoid options
        # are present, they are processed in order.
        outgoing-port-avoid: "4600-4700, 8300-8700"

        # number of outgoing simultaneous tcp buffers to hold per thread.
        outgoing-num-tcp: 10

        # number of incoming simultaneous tcp buffers to hold per thread.
        incoming-num-tcp: 10

        # buffer size for UDP port 53 incoming (SO_RCVBUF socket option).
        # 0 is system default.  Use 4m to catch query spikes for busy servers.
        so-rcvbuf: 0

        # buffer size for UDP port 53 outgoing (SO_SNDBUF socket option).
        # 0 is system default.  Use 4m to handle spikes on very busy servers.
        so-sndbuf: 0

        # Maximum UDP response size (not applied to TCP response).
        # Suggested values are 512 to 4096. Default is 4096. 65536 disables it.
        max-udp-size: 4096

        # buffer size for handling DNS data. No messages larger than this
        # size can be sent or received, by UDP or TCP. In bytes.
        msg-buffer-size: 65552

        # the amount of memory to use for the message cache.
        # plain value in bytes or you can append k, m or G. default is "4Mb".
        msg-cache-size: 4m

        # the number of slabs to use for the message cache.
        # the number of slabs must be a power of 2.
        # more slabs reduce lock contention, but fragment memory usage.
        msg-cache-slabs: 4

        # the number of queries that a thread gets to service.
        num-queries-per-thread: 1024

        # if very busy, 50% queries run to completion, 50% get timeout in msec
        jostle-timeout: 200

        # the time to live (TTL) value lower bound, in seconds. Default 0.
        # If more than an hour could easily give trouble due to stale data.
        cache-min-ttl: 0

        # the time to live (TTL) value cap for RRsets and messages in the
        # cache. Items are not cached for longer. In seconds.
        cache-max-ttl: 86400

        # the time to live (TTL) value cap for negative responses in the cache
        cache-max-negative-ttl: 0

        # the time to live (TTL) value for cached roundtrip times, lameness and
        # EDNS version information for hosts. In seconds.
        infra-host-ttl: 900

        # minimum wait time for responses, increase if uplink is long. In msec.
        infra-cache-min-rtt: 50

        # the maximum number of hosts that are cached (roundtrip, EDNS, lame).
        infra-cache-numhosts: 10000

        # Enable IPv4, "yes" or "no".
        do-ip4: yes

        # Enable IPv6, "yes" or "no".
        do-ip6: no

        # Enable UDP, "yes" or "no".
        do-udp: yes

        # Enable TCP, "yes" or "no".
        do-tcp: yes

        # upstream connections use TCP only (and no UDP), "yes" or "no"
        # useful for tunneling scenarios, default no.
        tcp-upstream: no

        # Maximum segment size (MSS) of TCP socket on which the server
        # responds to queries. Default is 0, system default MSS.
        tcp-mss: 0

        # Maximum segment size (MSS) of TCP socket for outgoing queries.
        # Default is 0, system default MSS.
        outgoing-tcp-mss: 0

        # Use systemd socket activation for UDP, TCP, and control sockets.
        use-systemd: no

        # Detach from the terminal, run in background, "yes" or "no".
        # Set the value to "no" when unbound runs as systemd service.
        do-daemonize: no

        # control which clients are allowed to make (recursive) queries
        # to this server. Specify classless netblocks with /size and action.
        # By default everything is refused, except for localhost.
        # Choose deny (drop message), refuse (polite error reply),
        # allow (recursive ok), allow_snoop (recursive and nonrecursive ok)
        # deny_non_local (drop queries unless can be answered from local-data)
        # refuse_non_local (like deny_non_local but polite error reply).
        access-control: 0.0.0.0/0 refuse
        access-control: 127.0.0.0/8 allow
        access-control: ::0/0 refuse
        access-control: ::1 allow
        access-control: ::ffff:127.0.0.1 allow

        # if given, a chroot(2) is done to the given directory.
        # i.e. you can chroot to the working directory, for example,
        # for extra security, but make sure all files are in that directory.
        #
        # If chroot is enabled, you should pass the configfile (from the
        # commandline) as a full path from the original root. After the
        # chroot has been performed the now defunct portion of the config
        # file path is removed to be able to reread the config after a reload.
        #
        # All other file paths (working dir, logfile, roothints, and
        # key files) can be specified in several ways:
        #   o as an absolute path relative to the new root.
        #   o as a relative path to the working directory.
        #   o as an absolute path relative to the original root.
        # In the last case the path is adjusted to remove the unused portion.
        #
        # The pid file can be absolute and outside of the chroot, it is
        # written just prior to performing the chroot and dropping permissions.
        #
        # Additionally, unbound may need to access /dev/random (for entropy).
        # How to do this is specific to your OS.
        #
        # If you give "" no chroot is performed. The path must not end in a /.
        chroot: ""

        # if given, user privileges are dropped (after binding port),
        # and the given username is assumed. Default is user "unbound".
        # If you give "" no privileges are dropped.
        username: ""

        # the working directory. The relative files in this config are
        # relative to this directory. If you give "" the working directory
        # is not changed.
        # If you give a server: directory: dir before include: file statements
        # then those includes can be relative to the working directory.
        directory: ""

        # the log file, "" means log to stderr.
        # Use of this option sets use-syslog to "no".
        logfile: "#{unbound_logs_directory}\\unbound.log"

        # Log to syslog(3) if yes. The log facility LOG_DAEMON is used to
        # log to. If yes, it overrides the logfile.
        use-syslog: no

        # Log identity to report. if empty, defaults to the name of argv[0]
        # (usually "unbound").
        # log-identity: ""

        # print UTC timestamp in ascii to logfile, default is epoch in seconds.
        log-time-ascii: yes

        # print one line with time, IP, name, type, class for every query.
        log-queries: yes

        # print one line per reply, with time, IP, name, type, class, rcode,
        # timetoresolve, fromcache and responsesize.
        log-replies: yes

        # Harden against very small EDNS buffer sizes.
        harden-short-bufsize: yes

        # Harden against unseemly large queries.
        harden-large-queries: yes

        # Harden against out of zone rrsets, to avoid spoofing attempts.
        harden-glue: yes

        # Harden against receiving dnssec-stripped data. If you turn it
        # off, failing to validate dnskey data for a trustanchor will
        # trigger insecure mode for that zone (like without a trustanchor).
        # Default on, which insists on dnssec data for trust-anchored zones.
        harden-dnssec-stripped: yes

        # Harden against queries that fall under dnssec-signed nxdomain names.
        harden-below-nxdomain: yes

        # if yes, the above default do-not-query-address entries are present.
        # if no, localhost can be queried (for testing and debugging).
        do-not-query-localhost: no

        # By default, for a number of zones a small default 'nothing here'
        # reply is built-in.  Query traffic is thus blocked.  If you
        # wish to serve such zone you can unblock them by uncommenting one
        # of the nodefault statements below.
        # You may also have to use domain-insecure: zone to make DNSSEC work,
        # unless you have your own trust anchors for this zone.
        local-zone: "localhost." nodefault
        local-zone: "127.in-addr.arpa." nodefault
        # local-zone: "10.in-addr.arpa." nodefault
        # local-zone: "16.172.in-addr.arpa." nodefault
        # local-zone: "17.172.in-addr.arpa." nodefault
        # local-zone: "18.172.in-addr.arpa." nodefault
        # local-zone: "19.172.in-addr.arpa." nodefault
        # local-zone: "20.172.in-addr.arpa." nodefault
        # local-zone: "21.172.in-addr.arpa." nodefault
        # local-zone: "22.172.in-addr.arpa." nodefault
        # local-zone: "23.172.in-addr.arpa." nodefault
        # local-zone: "24.172.in-addr.arpa." nodefault
        # local-zone: "25.172.in-addr.arpa." nodefault
        # local-zone: "26.172.in-addr.arpa." nodefault
        # local-zone: "27.172.in-addr.arpa." nodefault
        # local-zone: "28.172.in-addr.arpa." nodefault
        # local-zone: "29.172.in-addr.arpa." nodefault
        # local-zone: "30.172.in-addr.arpa." nodefault
        # local-zone: "31.172.in-addr.arpa." nodefault
        local-zone: "168.192.in-addr.arpa." nodefault
        # local-zone: "0.in-addr.arpa." nodefault

        # If unbound is running service for the local host then it is useful
        # to perform lan-wide lookups to the upstream, and unblock the
        # long list of local-zones above.  If this unbound is a dns server
        # for a network of computers, disabled is better and stops information
        # leakage of local lan information.
        unblock-lan-zones: yes

        # The insecure-lan-zones option disables validation for
        # these zones, as if they were all listed as domain-insecure.
        insecure-lan-zones: yes
  CONF
end

#
# WINDOWS SERVICE
#

service_name = node['service']['unbound']
powershell_script 'unbound_as_service' do
  code <<~POWERSHELL
    $ErrorActionPreference = 'Stop'

    $securePassword = ConvertTo-SecureString "#{service_password}" -AsPlainText -Force

    # Note the .\\ is to get the local machine account as per here:
    # http://stackoverflow.com/questions/313622/powershell-script-to-change-service-account#comment14535084_315616
    $credential = New-Object pscredential((".\\" + "#{service_username}"), $securePassword)

    $service = Get-Service -Name '#{service_name}' -ErrorAction SilentlyContinue
    if ($service -eq $null)
    {
        New-Service `
            -Name '#{service_name}' `
            -BinaryPathName '#{unbound_base_directory}\\unbound.exe -w service -c #{unbound_base_directory}\\#{unbound_config_file}' `
            -Credential $credential `
            -DisplayName '#{service_name}' `
            -StartupType Disabled
    }

    # Set the service to restart if it fails
    # sc.exe failure #{service_name} reset=86400 actions=restart/5000
  POWERSHELL
end

#
# ALLOW UNBOUND THROUGH THE FIREWALL
#

firewall_rule 'unbound-dns-udp' do
  command :allow
  description 'Allow Unbound DNS (UDP) proxy traffic'
  dest_port 53
  direction :in
  protocol :udp
end

firewall_rule 'unbound-dns-tcp' do
  command :allow
  description 'Allow Unbound DNS (TCP) proxy traffic'
  dest_port 53
  direction :in
  protocol :tcp
end

#
# WINDOWS DNS SETTINGS
#

# Disable the caching of negative DNS responses because that would stop unbound from working as a DNS for a period of time
# if there is a failed DNS request (e.g. the unbound machine is busy or something)
registry_key 'HKLM\\SYSTEM\\CurrentControlSet\\Services\\Dnscache\\Parameters' do
  values [
    {
      name: 'NegativeCacheTime',
      type: :dword,
      data: 0x0
    },
    {
      name: 'NetFailureCacheTime',
      type: :dword,
      data: 0x0
    },
    {
      name: 'NegativeSOACacheTime',
      type: :dword,
      data: 0x0
    },
    {
      name: 'MaxNegativeCacheTtl',
      type: :dword,
      data: 0x0
    }
  ]
  action :create
end
