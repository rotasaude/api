require "rails_helper"
require "zlib"
require "rubygems/package"

# O perfil RIRA é lido do pacote OFICIAL versionado em spec/fixtures/rira
# (br.gov.saude.rira.fhir, CC0). Estes specs travam cada URL do YAML ao pacote.
RSpec.describe Regulation::RiraProfile, type: :model do
  # Método, e não constante: dentro de um bloco do RSpec ela cairia em Object.
  def self.fixture = Rails.root.join("spec/fixtures/rira/br.gov.saude.rira.fhir-1.0.0-release.tgz")

  def self.package_files
    @package_files ||= Zlib::GzipReader.open(fixture) do |gz|
      files = {}
      Gem::Package::TarReader.new(gz).each { |e| files[e.full_name] = e.read if e.file? && e.full_name.end_with?(".json") }
      files
    end
  end

  def package_files = self.class.package_files

  def resources(prefix)
    package_files.select { |name, _| File.basename(name).start_with?("#{prefix}-") }
                 .transform_values { |raw| JSON.parse(raw) }
  end

  def urls(prefix) = resources(prefix).values.map { |r| r["url"] }

  def resource_by_name(prefix, name) = resources(prefix).values.find { |r| r["name"] == name || r["id"] == name }

  let(:profile) { described_class.current }

  it "as constantes ficam no próprio perfil: nada vaza para Regulation nem para Object" do
    expect(described_class::PATH).to eq(Rails.root.join("config/rnds/rira_1_0.yml"))
    expect(Regulation.const_defined?(:PATH, false)).to be(false)
    expect(Object.const_defined?(:FIXTURE, false)).to be(false)
  end

  it "o SHA-256 do fixture é o do YAML" do
    expect(Digest::SHA256.file(self.class.fixture).hexdigest).to eq(profile.package[:sha256])
    pkg = JSON.parse(package_files.fetch("package/package.json"))
    expect(pkg["name"]).to eq(profile.package[:id])
    expect(pkg["version"]).to eq(profile.package[:version])
  end

  it "cada profiles.* é o url de um StructureDefinition do pacote" do
    expect(profile.profiles.keys).to match_array(%i[composition appointment service_request condition])
    profile.profiles.each_value { |url| expect(urls("StructureDefinition")).to include(url) }
  end

  it "cada code_systems.* do IG é o url de um CodeSystem do pacote" do
    ig = profile.code_systems.slice(:document_type, :modality, :status, :participant_type)
    expect(ig.keys.size).to eq(4)
    ig.each_value { |url| expect(urls("CodeSystem")).to include(url) }
    # os de terminologia nacional também estão no pacote
    profile.code_systems.slice(:sigtap, :cbo, :cid10, :ciap2).each_value { |url| expect(urls("CodeSystem")).to include(url) }
  end

  it "os sete MIRA_STATUSES são exatamente os concept.code de BRStatusRegulacaoAssistencial" do
    cs = resources("CodeSystem").values.find { |r| r["url"] == profile.code_systems[:status] }
    expect(cs["concept"].map { |c| c["code"] }).to match_array(Regulation::RndsCatalog::MIRA_STATUSES)
  end

  it "09 e 04 estão em ValueSet-BRModalidadeAssistencialMIRA" do
    vs = resources("ValueSet").values.find { |r| r["name"].to_s.include?("ModalidadeAssistencialMIRA") || r["id"].to_s.include?("ModalidadeAssistencialMIRA") }
    codes = vs["compose"]["include"].flat_map { |i| i["concept"].map { |c| c["code"] } }
    expect(codes).to include("09", "04")
    expect(Regulation::RndsLimits::MODALITY).to eq("09")
  end

  it "os códigos do STATUS_RELATION existem nos ValueSets de status do pacote" do
    codes = lambda do |id|
      vs = resources("ValueSet").values.find { |r| r["url"].end_with?("/#{id}") }
      vs["compose"]["include"].flat_map { |i| (i["concept"] || []).map { |c| c["code"] } }
    end
    appointment = codes.call("BRStatusAgendamentoRegulacaoAssistencial")
    request = codes.call("BRStatusRequisicaoRegulacaoAssistencial")
    Regulation::RndsCatalog::STATUS_RELATION.each_value do |(appt, sr)|
      expect(appointment).to include(appt)
      expect(request).to include(sr)
    end
  end

  it "o Composition fixa custodian 0..0, section.title 0..0 e relatesTo 0..1" do
    sd = resources("StructureDefinition").values.find { |r| r["url"] == profile.profiles[:composition] }
    el = sd["differential"]["element"].index_by { |e| e["id"] }
    expect(el["Composition.custodian"]["max"]).to eq("0")
    expect(el["Composition.section.title"]["max"]).to eq("0")
    expect(el["Composition.relatesTo"]["max"]).to eq("1")
    expect(el["Composition.category"]["min"]).to eq(1)
  end

  it "confirmed é true e só doc_type é hipótese" do
    expect(profile.confirmed).to be(true)
    expect(profile.doc_type).to eq(value: "RIRA", hypothesis: true)
    expect(profile.date_fields).to eq(scheduled_at: "Appointment.start", requested_at: "ServiceRequest.authoredOn", authorized_at: "Appointment.created")
    expect(profile.identifiers[:requester_prefix]).to eq("http://www.saude.gov.br/fhir/r4/NamingSystem/BRRNDS-")
  end
end
