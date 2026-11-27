# frozen_string_literal: true
require 'json'
require 'open3'
require 'timeout'
require 'uri'

module SworncardSetup
  class SetupError < StandardError; end

  # The system dialog returns its answer only to this process through a private pipe.
  DIALOG = <<~'APPLESCRIPT'
    on run argv
      try
        set promptText to "Вставьте PAT подключения из кабинета Idemnia." & return & return & "Сервер: " & item 1 of argv & return & "Токен будет сохранён в личном файле настроек Codex на этом Mac."
        set reply to display dialog promptText with title "SwornCard · Подключение к Codex" default answer "" with hidden answer buttons {"Отмена", "Сохранить"} default button "Сохранить" cancel button "Отмена"
        return text returned of reply
      on error number -128
        return ""
      end try
    end run
  APPLESCRIPT

  def self.endpoint
    manifest = File.expand_path('../../../.mcp.json', __dir__)
    url = JSON.parse(File.read(manifest)).fetch('mcpServers').fetch('sworncard').fetch('url')
    uri = URI.parse(url)
    unless uri.to_s == 'https://connect.sworncard.ru/mcp'
      raise SetupError, 'Окно этой версии предназначено для RU-подключения SwornCard.'
    end
    url
  end

  def self.codex_binary
    apps = ['/Applications/ChatGPT.app', '/Applications/Codex.app']
    paths = ['Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex', 'Contents/Resources/codex']
    apps.product(paths).map { |app, path| File.join(app, path) }.find { |file| File.file?(file) && File.executable?(file) } ||
      raise(SetupError, 'Не найден Codex Desktop в папке «Программы».')
  end

  def self.ask(url)
    answer, status = Open3.capture2('/usr/bin/osascript', '-e', DIALOG, url, err: File::NULL)
    raise SetupError, 'Не удалось открыть окно ввода PAT.' unless status.success?
    answer.chomp
  end

  def self.rpc(input, output, id, method, params)
    input.puts(JSON.generate(id: id, method: method, params: params))
    while (line = output.gets)
      reply = JSON.parse(line)
      next unless reply['id'] == id
      return reply.fetch('result') unless reply.key?('error')
      break
    end
    raise SetupError, 'Codex не подтвердил изменение. Проверьте настройки и повторите подключение.'
  end

  def self.save(binary, url, token)
    match = /\Ascpat1\.(pc_[A-Za-z0-9_-]{43})\.[A-Za-z0-9_-]{43}\z/.match(token)
    raise SetupError, 'Формат PAT не распознан. Скопируйте весь токен из Idemnia.' unless match
    server = "sworncard_#{match[1]}"
    home = File.expand_path(ENV.fetch('CODEX_HOME', '~/.codex'))
    config = File.join(home, 'config.toml')
    # Refuse shared files before handing the credential to the config writer.
    if File.exist?(config) || File.symlink?(config)
      info = File.lstat(config)
      unless info.file? && info.uid == Process.uid && (info.mode & 0077).zero?
        raise SetupError, 'Личный config.toml должен быть обычным файлом, доступным только владельцу.'
      end
    end
    env = { 'HOME' => Dir.home, 'CODEX_HOME' => home, 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin' }
    Open3.popen3(env, binary, 'app-server', '--listen', 'stdio://',
                 unsetenv_others: true, chdir: '/', umask: 0077) do |input, output, err, child|
      # Drain diagnostics privately. Codex errors can include configuration values.
      drain = Thread.new { IO.copy_stream(err, File::NULL) rescue nil }
      begin
        Timeout.timeout(20) do
          rpc(input, output, 1, 'initialize', {clientInfo: {name: 'sworncard-setup', version: '1'}})
          input.puts('{"method":"initialized"}')
          layers = rpc(input, output, 2, 'config/read', {includeLayers: true}).fetch('layers')
          personal = layers.find { |layer| layer.dig('name', 'type') == 'user' }
          raise SetupError, 'Codex не предоставил личный профиль для записи.' unless personal
          current = personal.dig('config', 'mcp_servers', server)
          if current && !(current.keys.sort == %w[http_headers url] && current['url'] == url &&
                          current['http_headers'].is_a?(Hash) && current['http_headers'].keys == ['Authorization'])
            raise SetupError, 'У этого подключения уже есть собственные настройки MCP. Они сохранены.'
          end
          value = {url: url, http_headers: {'Authorization' => "Bearer #{token}"}}
          rpc(input, output, 3, 'config/value/write', {
            keyPath: "mcp_servers.#{server}", value: value, mergeStrategy: 'replace',
            expectedVersion: personal.fetch('version')
          })
        end
      ensure
        input.close
        unless child.join(1)
          Process.kill('KILL', child.pid) rescue nil
        end
        drain.join(1)
      end
    end
  end

  def self.run
    raise SetupError, 'Запустите настройку из установленного плагина на macOS.' unless RUBY_PLATFORM.include?('darwin') && ARGV.empty?
    url = endpoint
    binary = codex_binary
    token = ask(url)
    return 'Настройка отменена.' if token.empty?
    save(binary, url, token)
    'Настройка сохранена. Откройте новый чат Codex и запросите список сервисов SwornCard.'
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    puts SworncardSetup.run
  rescue SworncardSetup::SetupError => error
    warn error.message
    exit 1
  rescue StandardError
    warn 'Не удалось подтвердить сохранение в Codex. Можно повторить настройку.'
    exit 1
  end
end
