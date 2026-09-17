require "rails_helper"

# Spec da API de manutenção §4: staging roda com RAILS_ENV=staging e precisa de
# tudo que endurece produção. `Rails.env.production?` com o sentido de "ambiente
# publicado" deixa staging sem cookie Secure, sem TLS no banco da cidade e sem
# HostAuthorization — e a suíte, que roda em test, não percebe. A pergunta certa é
# Rota.deployed? (lib/rota.rb). config/environments/ fica de fora: ali cada
# arquivo É o ambiente.
#
# Fix wave (Important #4): o padrão original só pegava `Rails.env.production?`
# e comparação de string. Comparação de símbolo (`Rails.env.to_sym == :production`)
# e formas de pertencimento (`%w[production].include?(Rails.env)`,
# `Rails.env.in?(%w[production])`) são falsos negativos alcançáveis — o padrão
# agora cobre as duas.
RSpec.describe "Deployed environment guard" do
  def pattern
    /Rails\.env\.production\?
    |==\s*["']production["']
    |["']production["']\s*==
    |==\s*:production
    |:production\s*==
    |%w\[[^\]]*\bproduction\b[^\]]*\]\.include\?\(Rails\.env\)
    |Rails\.env\.in\?\(%w\[[^\]]*\bproduction\b[^\]]*\]\)
    /x
  end

  # Fix wave (Important #4): script/**/*.rb, Rakefile e config.ru entram no
  # escopo — script/staging_boot_check.rb é o exemplo que motivou a checagem
  # (veja o exemplo "does not flag..." abaixo), mas o pattern não distingue por
  # arquivo, só por conteúdo.
  def scanned_files
    Dir.chdir(Rails.root) do
      files = %w[app config lib db script].flat_map { |root| Dir.glob("#{root}/**/*.{rb,rake}") }
      files += Dir.glob("bin/*").select { |path| File.file?(path) }
      files += %w[Rakefile config.ru].select { |path| File.file?(path) }
      files.reject { |path| path.start_with?("config/environments/") }.sort
    end
  end

  def offending_lines
    Dir.chdir(Rails.root) do
      scanned_files.flat_map do |path|
        File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |line, i|
          next if line.lstrip.start_with?("#")

          "#{path}:#{i + 1}: #{line.strip}" if line.match?(pattern)
        end
      end
    end
  end

  it "asks Rota.deployed? instead of tying a protection to the production environment" do
    expect(offending_lines).to eq([])
  end

  it "the pattern catches the forms it exists for" do
    [
      "secure: Rails.env.production?",
      'return [] unless env.to_s == "production"',
      "raise ConfigMissing if 'production' == env",
      "Rails.env.to_sym == :production",
      "%w[production].include?(Rails.env)",
      "Rails.env.in?(%w[production])"
    ].each { |sample| expect(sample).to match(pattern) }

    expect("DEPLOYED_ENVS = %w[production staging].freeze").not_to match(pattern)
  end

  # Fix wave (Important #3): as duas checagens acima provam que o padrão está
  # certo e que a lista está vazia — mas nenhuma delas prova que o scan chega
  # nos arquivos que importam. Um scanned_files que devolvesse [] por engano
  # (um Dir.glob quebrado, uma raiz errada) faria a primeira checagem passar
  # vazia, do jeito errado.
  it "actually scans the files these checks care about" do
    expect(scanned_files).to include(
      "app/services/city_database.rb",
      "lib/platform_hosts.rb",
      "db/seeds.rb"
    )
    expect(scanned_files.size).to be > 100
  end

  # Fix wave (Important #4): staging_boot_check.rb é staging-specific de
  # propósito (checa Rails.env.staging?, nunca production) — precisa continuar
  # fora do padrão mesmo com script/**/*.rb agora escaneado.
  it "does not flag script/staging_boot_check.rb, which is staging-specific by design" do
    expect(scanned_files).to include("script/staging_boot_check.rb")

    lines = File.readlines(Rails.root.join("script/staging_boot_check.rb"), encoding: "UTF-8")
    matching = lines.reject { |line| line.lstrip.start_with?("#") }.select { |line| line.match?(pattern) }

    expect(matching).to eq([])
  end
end
