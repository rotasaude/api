require "rails_helper"

# Módulo 28 (ADR 0046; spec decisão 13 e "Equipes de saúde bucal"; contrato
# §16 O15; Task 16): indicadores B1 (primeira consulta programática) e B2
# (tratamento concluído) da eSB, com os CBOs e o denominador das notas
# metodológicas. Só contagens.
RSpec.describe DentalCare::Indicators do
  let!(:city) { dental_city! }
  let(:unit) { create_unit("UBS Bucal #{SecureRandom.hex(2)}") }
  let(:dentist) { dentist!(unit) }
  let(:esf) { team!(kind: "70", name: "eSF Jardim") }
  let(:esb) { team!(kind: DentalCare::Catalog::ORAL_HEALTH_TEAM_KIND, name: "eSB Jardim", associated_team: esf) }
  let(:citizens) { Hash.new { |hash, key| hash[key] = verified_citizen!(hash.size + 1) } }
  let(:october) { Time.zone.local(2026, 10, 10, 10) }

  def team!(unit: self.unit, **attrs)
    HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), **attrs)
  end

  def member!(user, team: esb, since: Date.new(2025, 1, 1), ended_on: nil)
    HealthTeamMember.create!(professional: user.professional, health_team: team, started_on: since, ended_on: ended_on,
                             cbo_code: user.professional.links.active.first.cbo_code)
    user
  end

  # Consulta odontológica finalizada em `at`, gravada direto (rascunho e então
  # a finalização), como no spec das metas do CEO.
  def consultation!(by:, citizen:, type: 1, outcomes: [ 16 ], at: october, unit: self.unit, baseline: false, kind: "dental")
    consultation = dental_draft_row!(unit: unit, by: by, citizen: citizen, baseline: baseline, kind: kind)
    finalize!(consultation, at: at, type: type, outcomes: outcomes)
  end

  def finalize!(consultation, at:, type:, outcomes:)
    plain = consultation.baseline || consultation.kind == "general"
    consultation.update_columns(status: "finalized", finalized_at: at, care_type: consultation.baseline ? nil : (plain ? 1 : 2),
                                dental_consultation_type: plain ? nil : type, dental_outcomes: plain ? [] : outcomes)
    consultation
  end

  # Paciente digitado (sem o caminho do par validado) numa consulta da eSB.
  def typed_consultation!(patient, by: dentist)
    attendance = consulting_attendance!(unit, citizen: citizens[citizens.size + 1], doctor: by)
    link = by.professional.links.active.first
    consultation = Consultation.create!(attendance: attendance, patient: patient, author_user: by, professional_link: link,
                                        cbo_code: link.cbo_code, status: "draft", kind: "dental", started_at: Time.current)
    finalize!(consultation, at: october, type: 1, outcomes: [ 16 ])
  end

  def indicators(team: esb, period: "2026-10") = described_class.call(team: team, period: period)
  def b1 = indicators.fetch(:b1).fetch(:numerator)
  def b2 = indicators.fetch(:b2)

  before { member!(dentist) }

  describe "B1" do
    it "duas primeiras consultas do mesmo paciente com o mesmo dentista na janela → 1" do
      consultation!(by: dentist, citizen: citizens[1], at: october - 3.months)
      consultation!(by: dentist, citizen: citizens[1])
      expect(b1).to eq(1)
    end

    it "o mesmo paciente com dois dentistas da eSB → 2" do
      other = member!(dentist!(unit, cbo: "223293"))
      consultation!(by: dentist, citizen: citizens[1])
      consultation!(by: other, citizen: citizens[1])
      expect(b1).to eq(2)
    end

    it "TSB e especialista do CEO (223212) da eSB não contam; retorno, baseline e consulta geral também não" do
      consultation!(by: member!(auxiliary!(unit, cbo: "322405")), citizen: citizens[1])
      consultation!(by: member!(dentist!(unit, cbo: "223212")), citizen: citizens[2])
      consultation!(by: dentist, citizen: citizens[3], type: 2)
      consultation!(by: dentist, citizen: citizens[4], baseline: true)
      consultation!(by: dentist, citizen: citizens[5], kind: "general")
      expect(b1).to eq(0)
    end

    it "fora da janela de 12 meses, em outra unidade, ou de quem não era membro na data → não conta" do
      consultation!(by: dentist, citizen: citizens[1], at: Time.zone.local(2025, 10, 31, 23)) # antes de 2025-11
      consultation!(by: dentist, citizen: citizens[2], at: Time.zone.local(2026, 11, 1, 1))  # depois de outubro
      elsewhere = create_unit("UBS Outra #{SecureRandom.hex(2)}")
      link_professional!(dentist, elsewhere, cbo: "223208")
      consultation!(by: dentist, citizen: citizens[3], unit: elsewhere)
      late = member!(dentist!(unit, cbo: "223293"), since: Date.new(2026, 10, 20))
      consultation!(by: late, citizen: citizens[4])
      left = member!(dentist!(unit, cbo: "223293"), since: Date.new(2025, 1, 1), ended_on: Date.new(2026, 9, 30))
      consultation!(by: left, citizen: citizens[5])
      consultation!(by: dentist, citizen: citizens[6], at: Time.zone.local(2025, 11, 1, 0, 30)) # primeira hora da janela
      expect(b1).to eq(1)
    end

    it "paciente sem CPF com CNS válido conta; sem CPF e sem CNS válido, não" do
      typed_consultation!(registry_no_cpf_patient!)
      typed_consultation!(registry_no_cpf_patient!(cns: nil))
      expect(b1).to eq(1)
    end
  end

  describe "B2" do
    it "desfecho 15 depois da primeira consulta conta; o de paciente sem primeira consulta não entra" do
      consultation!(by: dentist, citizen: citizens[1], at: october - 2.months)
      consultation!(by: dentist, citizen: citizens[1], type: 2, outcomes: [ 15 ])
      consultation!(by: dentist, citizen: citizens[2])
      consultation!(by: dentist, citizen: citizens[3], type: 2, outcomes: [ 15 ])
      expect(b2).to eq(numerator: 1, denominator: 2)
    end

    it "desfecho 15 antes da primeira consulta não conta" do
      consultation!(by: dentist, citizen: citizens[1], type: 2, outcomes: [ 15 ], at: october - 2.months)
      consultation!(by: dentist, citizen: citizens[1])
      expect(b2).to eq(numerator: 0, denominator: 1)
    end
  end

  describe "denominador do B1" do
    it "população da eSF/eAP associada (CareLines::TeamPopulation.members)" do
      doctor = member!(doctor!(unit), team: esf)
      finalized_consultation!(unit: unit, doctor: doctor, citizen: citizens[1], exam_requests: [])
      population = CareLines::TeamPopulation.members(team: esf)
      expect(population.values.sum(&:size)).to be_positive
      expect(indicators.fetch(:b1).fetch(:denominator)).to eq(population.values.sum(&:size))
    end

    it "eSB sem associada, ou associada a eSF inativa → denominator nil" do
      consultation!(by: dentist, citizen: citizens[1])
      esb.update!(associated_team: nil)
      expect(indicators.fetch(:b1)).to eq(numerator: 1, denominator: nil)
      esb.update!(associated_team: esf)
      esf.update!(active: false)
      expect(indicators.fetch(:b1)).to eq(numerator: 1, denominator: nil)
    end
  end

  it "window: os 12 meses que terminam no fim do mês do período" do
    expect(described_class.window("2026-10")).to eq(Time.zone.local(2025, 11, 1)...Time.zone.local(2026, 11, 1))
  end
end
