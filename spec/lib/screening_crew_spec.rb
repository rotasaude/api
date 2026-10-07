require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s

# Spec §10: em Curitiba o acolhimento nasce assinado e ativo; a técnica de
# enfermagem ganha vínculo na UBS da semente; a unidade fica em walk_in; dois
# cidadãos de demanda espontânea com check-in. Idempotente.
RSpec.describe ScreeningCrew do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "as regras iniciais passam no gate da variante" do
    definition = { "name" => "acolhimento", "version" => 1, "kind" => "screening", "risk_rules" => described_class::RULES }
    expect(Protocols::Gate.call(definition).errors).to eq([])
    red = Screenings::RiskSuggestion.call({ vitals: { "systolic" => 185, "diastolic" => 110 }, bmi: nil, ciap2_code: "K86" },
                                          { age: 50, sex: "female" }, rules: described_class::RULES)
    expect(red[:color]).to eq("red")
  end

  it "o prefixo do telefone da semente não aparece em nenhum outro lib/*_crew.rb" do
    others = Dir[Rails.root.join("lib/*_crew.rb")].reject { |f| f.end_with?("/screening_crew.rb") }
    expect(others.select { |f| File.read(f).include?(described_class::PHONE_PREFIX) }).to eq([])
  end

  # Semente inteira no banco de teste, com o elenco que ela exige (mesmo setup
  # do SchedulingCrew); pega, p.ex., run_cycle! privado.
  describe ".seed_current_city" do
    let!(:city_record) { register_test_city! }

    before do
      create_default_protocol!
      admin = staff_with("admin@curitiba.demo", "municipal_admin")
      SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
      ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    end
    after { Rails.cache.clear }

    def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41")

    it "ativa o acolhimento assinado, vincula a técnica, põe a UBS em walk_in e faz dois check-ins; idempotente" do
      result = seed
      protocol = ProtocolDefinition.find_by!(name: described_class::NAME, status: "active")
      expect(protocol.definition["kind"]).to eq("screening")
      expect(protocol.definition["risk_rules"]).to eq(described_class::RULES)
      expect(result[:protocol]).to eq("#{protocol.name} v#{protocol.version} (active)")

      unit = HealthUnit.find_by!(name: described_class::UNIT)
      expect(unit.screening_scope).to eq("walk_in")
      tecnico = User.find_by!(email_address: "tecnico@curitiba.demo").professional
      expect(tecnico.links.active.where(health_unit: unit, cbo_code: "322205").count).to eq(1)
      expect(result).to include(technician_link: "322205", walk_ins: 2)
      expect(Attendance.waiting.where(health_unit: unit).count).to eq(2)

      counts = [ ProtocolDefinition.where(name: described_class::NAME).count, Citizen.count, Attendance.count,
                 tecnico.links.count ]
      expect(seed).to include(walk_ins: 0)
      expect([ ProtocolDefinition.where(name: described_class::NAME).count, Citizen.count, Attendance.count,
               tecnico.links.count ]).to eq(counts)
    end
  end
end
