require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/professional_crew")

RSpec.describe ProfessionalCrew do
  include ActiveSupport::Testing::TimeHelpers

  before do
    Current.city = TEST_CITY_A
    (CityProfile.current || CityProfile.new).update!(name: "Cidade Teste", uf: "PR", ibge_code: "4106902")
    SignatureCrew.seed_current_city(slug: "teste", password: "dev-password")
  end
  after { Current.reset }

  let(:admin) { staff_with("admin@teste.demo", "municipal_admin") }

  def seed = described_class.seed_current_city(slug: "teste", password: "dev-password", admin: admin)

  it "cria unidades, perfis, vínculos e turnos com forma real" do
    travel_to(Time.zone.parse("2026-10-05 10:00")) { seed }

    expect(HealthUnit.pluck(:name)).to include("UBS Jardim das Flores", "UBS Vila Esperança", "UPA 24h Centro")
    expect(Professional.count).to eq(3)
    expect(Professional.all).to all(satisfy { |p| Professionals::Cns.valid?(p.cns) && p.council_state == "PR" })

    medica = User.find_by!(email_address: "profissional@teste.demo").professional
    expect(medica.council).to eq("CRM")
    expect(medica.links.active.map(&:cbo_code)).to contain_exactly("225125", "225124")

    enfermeira = User.find_by!(email_address: "enfermeira@teste.demo").professional
    expect(enfermeira.links.where.not(ended_at: nil).count).to eq(1)

    tecnico = User.find_by!(email_address: "tecnico@teste.demo").professional
    shift = ProfessionalShift.valid_shifts.find_by!(professional: tecnico)
    expect(shift.ends_at - shift.starts_at).to eq(24.hours)

    overnight = ProfessionalShift.valid_shifts.where(professional: medica)
                                 .find { |s| s.starts_at.hour == 19 }
    expect(overnight.ends_at.to_date).to eq(overnight.starts_at.to_date + 1)

    novato = User.find_by!(email_address: "novato@teste.demo")
    expect(novato.has_role?("health_professional")).to be(true)
    expect(novato.professional).to be_nil
  end

  it "é idempotente: rodar duas vezes não duplica nada" do
    travel_to(Time.zone.parse("2026-10-05 10:00")) { seed }
    counts = -> { [ HealthUnit.count, Professional.count, ProfessionalLink.count, ProfessionalShift.count, User.count ] }
    before = counts.call
    travel_to(Time.zone.parse("2026-10-05 11:00")) { seed }
    expect(counts.call).to eq(before)
  end
end
