require 'spec_helper_acceptance'
require 'helpers/dump_sshd_ciphers'

test_name 'ssh class'

describe 'ssh class' do

  # NOTE: by default, include 'ssh' will automatically include the ssh_server
  let(:server_manifest) { "include 'ssh::server'" }

  let(:server_hieradata) do
    {
      'simp_options::trusted_nets' => ['ALL'],
      'ssh::server::conf::banner'  => '/dev/null',
      'ssh::server::conf::permitrootlogin' => true,
      'ssh::server::conf::passwordauthentication' => true,
    }
  end

  let(:client_manifest) { "include 'ssh::client'" }

  hosts_as('server').each do |_server|
    os = _server.hostname.split('-').first
    context "on #{os}:" do

      let(:server) { _server }

      let(:client) do
        os = server.hostname.split('-').first
        hosts_as('client').select { |x| x.hostname =~ /^#{os}-.+/ }.first
      end

      context 'with default parameters' do
        it 'should configure server with no errors' do
          install_package(server, 'epel-release')
          install_package(client, 'epel-release')
          set_hieradata_on(server, server_hieradata)
          apply_manifest_on(server, server_manifest, expect_changes: true)
        end

        it "should configure #{os}-server idempotently" do
          set_hieradata_on(server, server_hieradata)
          apply_manifest_on(server, server_manifest, catch_changes: true)
        end

        it "should configure #{os}-client with no errors" do
          apply_manifest_on(client, client_manifest, expect_changes: true)
        end
        it "should configure #{os}-client idempotently" do
          apply_manifest_on(client, client_manifest, catch_changes: true)
        end
      end

      context 'logging into machines as root' do

        it 'should set the root password' do
          on(hosts, "sed -i 's/enforce_for_root//g' /etc/pam.d/*")
          on(hosts, 'echo password | passwd root --stdin')
        end

        it 'should be able to ssh into localhost' do
          install_package(server, 'expect')
          install_package(client, 'expect')
          scp_to(hosts, './spec/acceptance/suites/default/files/ssh_test_script', '/usr/local/bin/ssh_test_script')
          on(hosts, "chmod +x /usr/local/bin/ssh_test_script")

          on(server, "/usr/local/bin/ssh_test_script root localhost password")

          dump_sshd_ciphers(server)
        end

        it "should be able to ssh into #{os}-client" do
          on(client, "/usr/local/bin/ssh_test_script root #{os}-server password")
        end
      end

      context 'with a test user' do
        let(:ssh_cmd) do
          "ssh -o StrictHostKeyChecking=no -i ~testuser/.ssh/id_rsa testuser@#{os}-server"
        end

        it 'should be able to log in with password' do
          #create a test user and set a password
          on(hosts, 'useradd testuser', accept_all_exit_codes: true)
          on(hosts, 'echo password | passwd testuser --stdin')

          on(client, "/usr/local/bin/ssh_test_script testuser #{os}-server password")
        end

        it 'should be able to log in with just a key' do
          # copy the key to local_keys
          scp_to(server,
                 './spec/acceptance/suites/default/files/id_rsa_pub.example',
                 '/etc/ssh/local_keys/testuser')
          on(server, 'chmod o+r /etc/ssh/local_keys/testuser')

          on(client, "su testuser -c 'mkdir /home/testuser/.ssh'")
          scp_to(client,
                 './spec/acceptance/suites/default/files/id_rsa_pub.example',
                 '/home/testuser/.ssh/id_rsa.pub')
          scp_to(client,
                 './spec/acceptance/suites/default/files/id_rsa.example',
                 '/home/testuser/.ssh/id_rsa')
          on(client, 'chown -R testuser:testuser /home/testuser')

          on(client, "#{ssh_cmd} echo Logged in successfully")
        end

        it 'should not accept old ciphers when not enabled' do
          disable_fallback_hieradata = server_hieradata.merge(
            { 'ssh::server::conf::enable_fallback_ciphers' => false }
          )
          set_hieradata_on(server, disable_fallback_hieradata)
          apply_manifest_on(server, server_manifest)

          # FIXME: This doesn't prove what it claims to.
          #
          # aes*-cbc aren't in the fallback ciphers, so they won't be accepted
          # whether enable_fallback_ciphers is enabled or not
          if fact_on(server, 'operatingsystem') == 'CentOS' && fact_on(server, 'operatingsystemmajrelease') == '6'
            on(client,
               "#{ssh_cmd} -o Ciphers=3des-cbc echo Logged in successfully",
               acceptable_exit_codes: [255])
          else
            on(client,
               "#{ssh_cmd} -o Ciphers=aes128-cbc,aes192-cbc,aes256-cbc echo Logged in successfully",
               acceptable_exit_codes: [255])
          end

          dump_sshd_ciphers(server,'fallback-ciphers-disabled', "`ssh::server::conf::enable_fallback_ciphers: false`")
        end

        it 'should prompt user to change password if expired and logging in with cert' do
          # reset and expire testuser password
          on(hosts, 'echo password | passwd testuser --stdin')
          on(hosts, 'chage -d 0 testuser')
          scp_to(hosts,
                 './spec/acceptance/suites/default/files/ssh_test_script_change_pass',
                 '/usr/local/bin/ssh_test_script_change_pass')
          on(hosts, 'chmod +x /usr/local/bin/ssh_test_script_change_pass')

          on(client, '/usr/local/bin/ssh_test_script_change_pass testuser ' \
                     "#{os}-server password correcthorsebatterystaple")

          on(client, '/usr/local/bin/ssh_test_script testuser ' \
                     "#{os}-server correcthorsebatterystaple")
        end

        it 'should prompt user to change password if expired' do
          # reset and expire testuser password
          on(hosts, 'echo password | passwd testuser --stdin')
          on(hosts, 'chage -d 0 testuser')
          # remove publc key from server
          on(server, 'rm -rf /etc/ssh/local_keys/*')

          on(client, '/usr/local/bin/ssh_test_script_change_pass testuser ' \
                     "#{os}-server password correcthorsebatterystaple")

          on(client, '/usr/local/bin/ssh_test_script testuser ' \
                     "#{os}-server correcthorsebatterystaple")
        end
      end

      context 'with additional custom settings via augeasproviders_ssh' do
        let(:server_hieradata_w_additions) do
          server_hieradata.merge({
          'ssh::server::conf::gssapiauthentication' => true,
          })
        end

        let(:server_manifest_w_additions) do
           <<-PP
              include 'ssh::server'

              sshd_config {'LogLevel': value => 'VERBOSE'}

               # SIMP-4440 example
               sshd_config {
                default:
                  ensure => 'present',
                  value  => 'yes',
                ;
                ['GSSAPIKeyExchange', 'GSSAPICleanupCredentials']:
                  # use defaults
                ;
               }
           PP
        end

        let(:client_manifest_w_additions) do
           <<-PP
              include 'ssh::client'
           PP
        end



        it 'should permit additional settings via the sshd_config type' do

          # Ensure the server is using the default test setup
          set_hieradata_on(server, server_hieradata)
          on(server, 'echo > /etc/ssh/sshd_config')
          apply_manifest_on(server, server_manifest)
          _normal_sshd_conf = on(server, 'cat /etc/ssh/sshd_config').stdout.to_s.split("\n")

          # Create the new test setup
          set_hieradata_on(server, server_hieradata_w_additions)
          apply_manifest_on(server, server_manifest_w_additions)
          _custom_sshd_conf = on(server, 'cat /etc/ssh/sshd_config').stdout.to_s.split("\n")

          # Compare the results
          expect( (_custom_sshd_conf - _normal_sshd_conf).sort ).to eq [
            'GSSAPIAuthentication yes',
            'GSSAPICleanupCredentials yes',
            'GSSAPIKeyExchange yes',
            'LogLevel VERBOSE'
          ]

        end
        it 'should permit additional settings via the ssh_config type' do
        end
      end
    end
  end
end
