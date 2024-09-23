title "FirstSpirit service section"

control "environment" do
  impact 0.5
  title "Environment variables compliance"
  desc "Checks environment variables"

  describe os_env('FS_BASEDIR') do
    its('content') { should_not match /^$|\s+/ }
  end

  describe os_env('FS_VERSION') do
    its('content') { should_not match /^$|\s+/ }
  end

  describe os_env('FS_JAVA_HOME') do
    its('content') { should_not match /^$|\s+/ }
  end
end

control "filesystem" do
  impact 0.5
  title "Filesystem compliance"
  desc "Checks basic files in filesystem"

  describe file("/opt/firstspirit5/.fs.lock") do
    it { should exist }
    it { should be_file }
    its ('content') { should match("100") }
  end

  describe file("/opt/firstspirit5/.version") do
    it { should exist }
    it { should be_file }
    its ('content') { should match(input('firstspirit_version')) }
  end

  describe file("/opt/firstspirit5/server/lib-isolated/fs-isolated-server.jar") do
    it { should exist }
    it { should be_file }
  end

  describe file("/usr/local/bin/docker-entrypoint.sh") do
    it { should exist }
    it { should be_file }
  end

  describe file("/opt/www/html") do
    it { should exist }
    it { should be_directory }
    it { should be_owned_by 'fs' }
  end

end

control "process" do
  impact 0.5
  title "OS process compliance"
  desc "Checks the software process compliance"

  describe processes('/usr/bin/tini -- docker-entrypoint.sh start') do
    it { should be_running }
    its('users') { should eq ['root'] }
  end

  describe processes('tail -F /opt/firstspirit5/log/fs-wrapper.log /opt/firstspirit5/log/fs-server.log') do
    it { should be_running }
    its('users') { should eq ['root'] }
  end

  describe processes('/opt/java/openjdk/bin/java') do
    it { should be_running }
    its('users') { should_not eq ['root'] }
  end
end

control "ports" do
  impact 0.5
  title "Ports compliance"
  desc "Checks the open ports compliance"

  describe port(8000) do
    it { should be_listening }
    its('protocols') { should include 'tcp' }
  end

  describe port(1088) do
    it { should be_listening }
    its('protocols') { should include 'tcp' }
  end

end
control "application" do
  impact 0.5
  title "Application compliance"
  desc "Checks the running application compliance"

  describe http('http://localhost:8000/login.jsp') do
    its('status') { should cmp 200 }
    its('body') { should match(input('firstspirit_version_short').to_s) }
  end

  describe command(' cat /opt/firstspirit5/log/fs-server.log | grep "FirstSpirit Server Version" | sed -E \'s/.*Version ([0-9.]+)\.[0-9]+.*/\1/\'') do
    its('stdout') { should match(input('firstspirit_version').to_s) }
  end
end
