require "rails_helper"

# Spec §5: o cookie de sessão é host-only — NUNCA `domain:`. Com domain, o cookie
# de uma cidade (ou do console) viajaria para todos os subdomínios. Os request
# specs provam o Set-Cookie em runtime; esta guarda pega a regressão no código,
# inclusive num controller que nenhum spec exercita.
RSpec.describe "Cookie domain guard" do
  def pattern
    /\bdomain:|:domain\s*=>|session_store/
  end

  def offending_lines
    Dir.chdir(Rails.root) do
      %w[app config lib].flat_map { |root| Dir.glob("#{root}/**/*.rb") }.sort.flat_map do |path|
        File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |line, i|
          next if line.lstrip.start_with?("#")

          "#{path}:#{i + 1}: #{line.strip}" if line.match?(pattern)
        end
      end
    end
  end

  it "no source file sets a cookie Domain or configures a session store" do
    expect(offending_lines).to eq([])
  end

  it "the pattern catches the forms it exists for" do
    [
      'cookies.signed[:session_id] = { value: id, domain: :all }',
      'cookies[:operator_session_id] = { :domain => ".rotasaude.app" }',
      'config.session_store :cookie_store, key: "_rota"'
    ].each { |sample| expect(sample).to match(pattern) }
  end
end
