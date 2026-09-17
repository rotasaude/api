require "rails_helper"

# Spec da API de manutenção §4: staging roda com RAILS_ENV=staging e precisa de
# tudo que endurece produção. `Rails.env.production?` com o sentido de "ambiente
# publicado" deixa staging sem cookie Secure, sem TLS no banco da cidade e sem
# HostAuthorization — e a suíte, que roda em test, não percebe. A pergunta certa é
# Rota.deployed? (lib/rota.rb). config/environments/ fica de fora: ali cada
# arquivo É o ambiente.
RSpec.describe "Deployed environment guard" do
  def pattern
    /Rails\.env\.production\?|==\s*["']production["']|["']production["']\s*==/
  end

  def scanned_files
    Dir.chdir(Rails.root) do
      files = %w[app config lib db].flat_map { |root| Dir.glob("#{root}/**/*.{rb,rake}") }
      files += Dir.glob("bin/*").select { |path| File.file?(path) }
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
      "raise ConfigMissing if 'production' == env"
    ].each { |sample| expect(sample).to match(pattern) }

    expect("DEPLOYED_ENVS = %w[production staging].freeze").not_to match(pattern)
  end
end
