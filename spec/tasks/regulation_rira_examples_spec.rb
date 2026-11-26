require "rails_helper"
require "rake"
require "tmpdir"

# Módulo 26c, Task 9: os exemplos RIRA em memória (sem banco) que a CI entrega ao
# validador oficial do HL7 (job `rira-validate`). Dados fictícios.
RSpec.describe "regulation:rira_examples", type: :model do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("regulation:rira_examples")
  end

  let(:dir) { Pathname(Dir.mktmpdir("rira-examples")) }
  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }

  after { FileUtils.remove_entry(dir) }

  def run_task(*args)
    Rake::Task["regulation:rira_examples"].reenable
    out = StringIO.new
    original, $stdout = $stdout, out
    Rake::Task["regulation:rira_examples"].invoke(*args)
    out.string
  ensure
    $stdout = original
  end

  def written = Regulation::RiraExamples.write(dir, now: now)
  def docs = written.to_h { |path| [ path.basename(".json").to_s, JSON.parse(path.read) ] }

  it "a rake escreve os 12 arquivos e imprime só os nomes" do
    output = run_task(dir.to_s)
    expect(Dir[dir.join("*.json")].map { |f| File.basename(f, ".json") }).to match_array(Regulation::RiraExamples::CASES.keys.map(&:to_s))
    expect(Regulation::RiraExamples::CASES.size).to eq(12)
    expect(output.lines.map(&:strip)).to match_array(Regulation::RiraExamples::CASES.keys.map { |k| "#{k}.json" })
    expect(output).not_to match(/\d{11}/)
  end

  it "cada arquivo tem RiraSkeleton.problems == [] e passa na RndsValidation" do
    Regulation::RiraExamples::CASES.each do |name, definition|
      written
      bundle = JSON.parse(dir.join("#{name}.json").read)
      expect(Regulation::RiraSkeleton.problems(bundle)).to eq([]), name.to_s
      status = definition.status
      expect(Regulation::RndsValidation.call(facts: definition.facts, status: status)).to eq(:ok), name.to_s
    end
  end

  it "nenhum CPF além do de teste do caso" do
    docs.each do |name, bundle|
      cpfs = bundle.to_json.scan(/\b\d{11}\b/).uniq
      expect(cpfs).to eq([ Regulation::RiraExamples::CASES.fetch(name.to_sym).facts.patient_cpf ].compact), name
    end
  end

  it "os sete MIRA_STATUSES aparecem; há urgent e routine; há rede própria e externa" do
    cases = Regulation::RiraExamples::CASES.values
    statuses = cases.map { |c| c.status.status }.uniq
    expect(statuses).to include(*Regulation::RndsCatalog::MIRA_STATUSES)
    priorities = cases.map { |c| c.facts.priority }
    expect(priorities).to include("urgent", "routine")
    expect(cases.map { |c| c.facts.own_network }.uniq).to contain_exactly(true, false)
  end

  it "o attended é de SIGTAP do grupo 03, o booked_replacing carrega o last_rnds_id e há CIAP-2" do
    all = docs
    attended = all.fetch("attended_procedure_group03")
    sigtap = attended["entry"].map { |e| e["resource"] }.find { |r| r["resourceType"] == "ServiceRequest" }.dig("code", "coding", 0, "code")
    expect(sigtap).to start_with("03")
    replacing = all.fetch("booked_replacing")["entry"].first["resource"]
    expect(replacing.dig("relatesTo", 0, "code")).to eq("replaces")
    expect(all.fetch("pending_ciap2").to_json).to include(Regulation::RiraProfile.current.code_systems[:ciap2])
  end

  it "cada documento é um Bundle document com os quatro recursos" do
    docs.each_value do |bundle|
      expect(bundle).to include("resourceType" => "Bundle", "type" => "document")
      expect(bundle["entry"].map { |e| e.dig("resource", "resourceType") }).to eq(%w[Composition Appointment ServiceRequest Condition])
    end
  end
end
