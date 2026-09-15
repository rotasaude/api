require "rails_helper"

# Spec banco-por-cidade §4: com um banco por cidade, réplicas migrando no boot
# correriam entre si e o boot cresceria com o número de cidades. Migração é passo
# explícito de deploy (bin/migrate).
RSpec.describe "Boot does not migrate" do
  def code_of(path)
    File.readlines(Rails.root.join(path)).reject { |line| line.strip.start_with?("#") }.join
  end

  it "keeps every migration task out of bin/docker-entrypoint" do
    expect(code_of("bin/docker-entrypoint")).not_to match(/db:(create|migrate|prepare|schema:load)|city:/)
  end

  it "migrates the platform databases and then every city in bin/migrate" do
    code = code_of("bin/migrate")

    expect(code.index("db:migrate")).to be < code.index("city:migrate:all")
    expect(File.executable?(Rails.root.join("bin/migrate"))).to be(true)
  end
end
