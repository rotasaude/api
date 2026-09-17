require "rails_helper"

# Spec da API de manutenção §10: nada na suíte (RAILS_ENV=test) carrega staging.
# O job staging-boot é o único lugar em que o ambiente sobe de verdade antes do
# deploy — esta guarda impede que ele suma do workflow sem ninguém notar.
RSpec.describe "CI workflow" do
  let(:jobs) { YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs") }

  it "boots RAILS_ENV=staging for real through script/staging_boot_check.rb" do
    job = jobs.fetch("staging-boot")

    expect(job.dig("env", "RAILS_ENV")).to eq("staging")
    expect(job.fetch("steps").map { |step| step["run"].to_s }.join("\n"))
      .to include("bin/rails runner script/staging_boot_check.rb")
  end

  it "keeps booting RAILS_ENV=production" do
    expect(jobs.fetch("production-boot").dig("env", "RAILS_ENV")).to eq("production")
  end
end
