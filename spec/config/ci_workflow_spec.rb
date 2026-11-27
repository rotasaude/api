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

  # Módulo 26c, revisão final I4: o jar do validador é de terceiro (asset de
  # release é mutável). O sha256 (o do metadado da release 7.0.6) é conferido
  # entre o download/cache e o Java, e o RAILS_MASTER_KEY só chega ao passo que
  # gera os exemplos.
  it "rira-validate confere o sha256 do validator_cli.jar e só o passo dos exemplos tem o RAILS_MASTER_KEY" do
    job = jobs.fetch("rira-validate")
    steps = job.fetch("steps")
    runs = steps.map { |step| step["run"].to_s }

    expect(job.fetch("env")).not_to have_key("RAILS_MASTER_KEY")
    expect(steps.select { |step| step.dig("env", "RAILS_MASTER_KEY") }.map { |step| step["run"] })
      .to eq([ 'bin/rails "regulation:rira_examples[tmp/rira-examples]"' ])
    expect(job.dig("env", "VALIDATOR_SHA256")).to eq("2686590539f0b3ba7683149b25d78249f6886c04e2c326e884c5049d8947df89")
    download = runs.index { |run| run.include?("curl") && run.include?("releases/download/7.0.6/validator_cli.jar") }
    check = runs.index { |run| run.include?("sha256sum -c") && run.include?("VALIDATOR_SHA256") }
    java = runs.index { |run| run.include?("java -jar") }
    expect([ download, check, java ]).to all(be_an(Integer))
    expect(download < check && check < java).to be(true)
  end
end
