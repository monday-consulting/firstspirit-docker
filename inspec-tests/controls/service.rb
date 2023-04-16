title "FirstSpirit service section"

control "basic-environment" do
  impact 0.5
  title "Environment variables compliance"
  desc "Checks environment variables"

  describe os_env('FS_BASEDIR') do
    its('content') {should_not match /^$|\s+/ }
  end

  describe os_env('FS_VERSION') do
    its('content') {should_not match /^$|\s+/ }
  end

  describe os_env('FS_JAVA_HOME') do
    its('content') {should_not match /^$|\s+/ }
  end
end

control "basic-filesystem" do
  impact 0.5
  title "Filesystem compliance"
  desc "Checks basic files in filesystem"

  describe file("/opt/firstspirit5/.version") do
    it {should exist}
    it {should be_file}
    its ('content') {should match(input('firstspirit_version'))}
  end

  describe file("/opt/firstspirit5/server/lib-isolated/fs-isolated-server.jar") do
    it {should exist}
    it {should be_file}
  end

  describe file("/usr/local/bin/docker-entrypoint.sh") do
    it {should exist}
    it {should be_file}
  end

  describe file("/opt/www/html") do
    it {should exist}
    it {should be_directory}
    it { should be_owned_by 'fs' }
  end

end
