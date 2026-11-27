# Run with macOS system Ruby. A real Codex binary can be supplied by CI.
require 'tmpdir'
require 'securerandom'
require 'fileutils'
require_relative '../codex/skills/sworncard-setup/scripts/setup-macos'

def check(condition, message)
  raise message unless condition
end

def must_refuse
  yield
  raise 'unexpected success'
rescue SworncardSetup::SetupError
  true
end

Dir.mktmpdir('sworncard-test-') do |root|
  ENV['HOME'] = root
  ENV['CODEX_HOME'] = File.join(root, 'settings')
  Dir.mkdir(ENV.fetch('CODEX_HOME'), 0700)
  config = File.join(ENV.fetch('CODEX_HOME'), 'config.toml')
  binary = ENV.fetch('TEST_CODEX_BINARY') { SworncardSetup.codex_binary }
  url = SworncardSetup.endpoint
  check(url == 'https://connect.sworncard.ru/mcp', 'unexpected public endpoint')
  check(system('/usr/bin/osacompile', '-o', File.join(root, 'dialog.scpt'), '-e', SworncardSetup::DIALOG), 'invalid dialog')
  must_refuse { SworncardSetup.save(binary, url, 'invalid') }
  check(!File.exist?(config), 'invalid input created a config')
  id = 'pc_' + SecureRandom.urlsafe_base64(32)
  issue = -> { "scpat1.#{id}.#{SecureRandom.urlsafe_base64(32)}" }
  first = issue.call
  second = issue.call
  File.write(config, %[# retain this comment\n[mcp_servers.other]\nurl = "https://example.invalid/mcp"\n])
  File.open(config, 'a') { |f| f.puts %[\n[plugins."sworncard-connect@sworncard-connect"]\nenabled = true] }
  ENV.delete('SWORNCARD_CONNECT_PAT')
  File.chmod(0644, config)
  must_refuse { SworncardSetup.save(binary, url, first) }
  File.chmod(0600, config)
  SworncardSetup.save(binary, url, first)
  SworncardSetup.save(binary, url, second)
  data = File.read(config)
  check(data.include?('enabled = false'), 'unused bundled MCP still enabled')
  check(data.include?(second) && !data.include?(first), 'rotation did not replace the token')
  check(data.include?('# retain this comment') && data.include?('[mcp_servers.other]'), 'unrelated configuration lost')
  check((File.stat(config).mode & 0077).zero?, 'config permissions')
  File.write(config, data.gsub(url, 'https://example.invalid/different'))
  before = File.read(config)
  must_refuse { SworncardSetup.save(binary, url, second) }
  check(File.read(config) == before, 'overwrote a conflicting server')
  # Inspect only disposable test state; never print contents.
  Dir.glob(File.join(root,'**','*'), File::FNM_DOTMATCH).each do |file|
    next if file == config || !File.file?(file)
    bytes = File.binread(file)
    check(!bytes.include?(first) && !bytes.include?(second), 'credential found outside personal config')
  end
  puts 'PASS: dialog compiles, invalid input, permissions, rotation, collision, unrelated settings, secret containment'
end
