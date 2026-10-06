require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/professional_crew")
require Rails.root.join("lib/triage_catalog_crew")
require Rails.root.join("lib/scheduling_crew")

# Semente do módulo 17 (spec §10): base de tipos; em Curitiba, o modelo
# "Manhã" nos turnos da médica; turnos da semana para a médica e a enfermeira;
# "Saúde do idoso" com regra de agendamento (rotina, 30 dias), pelo ciclo
# assinado. Idempotente.
RSpec.describe SchedulingCrew do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }

  before do
    create_default_protocol!
    %w[Centro Batel Portão].each { |name| Neighborhood.create!(name: name, source: "seed") }
    admin = staff_with("admin@curitiba.demo", "municipal_admin")
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    TriageCatalogCrew.seed_current_city(slug: "curitiba", ddd: "41")
  end
  after { Rails.cache.clear }

  def seed = described_class.seed_current_city(slug: "curitiba")

  let(:unit) { HealthUnit.find_by!(name: SchedulingCrew::UNIT) }
  let(:medica) { User.find_by!(email_address: "profissional@curitiba.demo").professional }
  let(:enfermeira) { User.find_by!(email_address: "enfermeira@curitiba.demo").professional }

  def future(professional)
    ProfessionalShift.valid_shifts.where(professional: professional).where("starts_at > ?", Time.current)
  end

  def at_unit(scope) = scope.joins(:professional_link).where(professional_links: { health_unit_id: unit.id })

  it "tipos, modelo na médica, turnos da semana e o idoso com agendamento; a segunda rodada não cria nada" do
    result = seed
    expect(result[:types]).to eq(4)
    template = ScheduleTemplate.find_by!(name: SchedulingCrew::TEMPLATE_NAME)
    expect(template.blocks.map { |b| b.values_at("starts", "ends", "kind") })
      .to eq([ %w[07:00 09:00 walk_in], %w[09:00 11:00 bookable], %w[11:00 12:00 blocked] ])
    expect(result[:templated]).to be >= 5

    expect(at_unit(future(medica)).pluck(:schedule_template_id).uniq).to eq([ template.id ])
    expect(future(enfermeira).pluck(:schedule_template_id).uniq).to eq([ nil ])
    expect(at_unit(future(medica)).count).to be >= 5

    idoso = ProtocolDefinition.find_by!(name: "saude-do-idoso", status: "active")
    expect(idoso.definition["scheduling"]).to eq(SchedulingCrew::SCHEDULING)
    expect(Protocols::Gate.call(idoso.definition)).to be_valid

    day = at_unit(future(medica)).order(:starts_at).first.starts_at.to_date
    slots = Scheduling::Availability.for(unit: unit, from: day, to: day,
                                         appointment_type: AppointmentType.find_by!(key: "consulta_medica"))
    expect(slots.select { |s| s.professional_id == medica.id }.map { |s| s.starts_at.strftime("%H:%M") })
      .to eq(%w[09:00 09:20 09:40 10:00 10:20 10:40])

    counts = [ ScheduleTemplate.count, ProfessionalShift.count, ProtocolDefinition.where(name: "saude-do-idoso").count ]
    again = seed
    expect([ ScheduleTemplate.count, ProfessionalShift.count, ProtocolDefinition.where(name: "saude-do-idoso").count ]).to eq(counts)
    expect(again).to include(new_shifts: 0, templated: 0)
  end

  # O ProfessionalCrew só lança a semana quando o vínculo não tem turno futuro
  # nenhum; rodada dias depois, a semana que sobrou é parcial. A semente da
  # agenda completa os dias úteis que faltam, já com o modelo na médica.
  it "rodada dias depois: lança os turnos que faltam na semana, com o modelo na médica, e não repete" do
    seed
    travel_to(4.days.from_now) do
      before_count = ProfessionalShift.count
      result = seed
      template = ScheduleTemplate.find_by!(name: SchedulingCrew::TEMPLATE_NAME)

      expect(result[:new_shifts]).to be > 0
      expect(ProfessionalShift.count - before_count).to eq(result[:new_shifts])

      ProfessionalCrew.business_days.each do |d|
        medica_day = at_unit(ProfessionalShift.valid_shifts.where(professional: medica))
                     .find_by(starts_at: ProfessionalCrew.at(d, 7), ends_at: ProfessionalCrew.at(d, 13))
        enf_day = at_unit(ProfessionalShift.valid_shifts.where(professional: enfermeira))
                  .find_by(starts_at: ProfessionalCrew.at(d, 7), ends_at: ProfessionalCrew.at(d, 19))
        expect(medica_day&.schedule_template_id).to eq(template.id), "médica sem turno com modelo em #{d}"
        expect(enf_day).to be_present, "enfermeira sem turno em #{d}"
        expect(enf_day.schedule_template_id).to be_nil
      end

      counts = ProfessionalShift.count
      expect(seed).to include(new_shifts: 0, templated: 0)
      expect(ProfessionalShift.count).to eq(counts)
    end
  end
end
