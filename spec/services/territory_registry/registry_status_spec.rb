require "rails_helper"

# Escala (revisão final do 24a, M2): uma ESF tem até 4.000 pessoas. A
# validade e a população da equipe não mandam ao banco listas de ids que
# crescem com a equipe (IN de ids saído do Ruby): o número de consultas e o
# tamanho de cada SQL ficam iguais entre uma equipe de 3 pessoas e uma de
# 3.000+ — na validade (24a) e na prévia das linhas de cuidado (23). Lista de
# ids que ainda precisa ir ao banco vai num bind só (= ANY(CAST($1 AS
# uuid[]))), fora do texto do SQL; um por CPF dos pares é SQL (NOT EXISTS).
RSpec.describe TerritoryRegistry::RegistryStatus do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:team) { care_team!(unit, doctor) }
  let(:area) { registry_micro_area!(code: "01", team: team) }

  # [consultas, maior SQL] do bloco (sem SCHEMA/TRANSACTION nem cache).
  def sql_profile(&block)
    sizes = []
    counter = lambda do |*, payload|
      sizes << payload[:sql].size unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    [ sizes.size, sizes.max ]
  end

  # n pacientes sem CPF (com CNS) cadastrados na microárea, em lote (insert_all
  # cifra pelas colunas do modelo).
  def bulk_registrations!(count, offset:)
    now = Time.current
    by = registry_acs_of(area).id
    patients = Array.new(count) do |i|
      { id: SecureRandom.uuid, no_cpf_reason: "3", cns: valid_cns(10_000 + offset + i), full_name: "Pessoa #{offset + i}",
        birth_date: "1980-01-01", sex: "female", created_at: now, updated_at: now }
    end
    Patient.insert_all!(patients)
    IndividualRegistration.insert_all!(patients.map do |p|
      { patient_id: p[:id], team_id: team.id, micro_area_id: area.id, refused: "false", registered_at: now, version: 1,
        registered_by_user_id: by, created_at: now, updated_at: now }
    end)
  end

  # n pacientes sem consulta nem cadastro cujo par validado mora num bairro
  # coberto pela unidade (P18: a equipe pelo território), em lote.
  def bulk_territorial!(count, offset:, neighborhood:)
    now = Time.current
    patients = Array.new(count) do |i|
      { id: SecureRandom.uuid, no_cpf_reason: "3", cns: valid_cns(50_000 + offset + i), full_name: "Vizinha #{offset + i}",
        birth_date: "1990-01-01", sex: "female", created_at: now, updated_at: now }
    end
    Patient.insert_all!(patients)
    Citizen.insert_all!(patients.each_with_index.map do |p, i|
      { cpf: valid_cpf(50_000 + offset + i), phone: format("4199%07d", offset + i), verification_level: "verified",
        patient_id: p[:id], neighborhood_id: neighborhood.id, created_at: now, updated_at: now }
    end)
  end

  # n pares validados SEM paciente num bairro coberto pela unidade (a única
  # equipe do bairro: entram na população como citizen:), em lote.
  def bulk_pairs!(count, offset:, neighborhood:)
    now = Time.current
    Citizen.insert_all!(Array.new(count) do |i|
      { cpf: valid_cpf(90_000 + offset + i), phone: format("4198%07d", offset + i), verification_level: "verified",
        neighborhood_id: neighborhood.id, created_at: now, updated_at: now }
    end)
  end

  # A prévia das linhas de cuidado (módulo 23) sobre a mesma população: uma
  # linha sem regra de problema (todos os pacientes passam por Facts.patients)
  # e uma com (Facts.problem_candidates cruza com os ids).
  def lines = @lines ||= [ adopted_line!("elderly_c6"), adopted_line!("diabetes_c4") ]

  def profiles
    {
      preview: lines.map { |line| sql_profile { CareLines::TeamPopulation.call(team: team, line: line, rules: line.eligibility) } },
      count: sql_profile { described_class.count(team: team, today: Time.zone.today) },
      # status fixo: a página mostra sempre cadastrados (o tipo de quem cai na
      # página muda as consultas da página, não o tamanho da equipe).
      page: sql_profile { described_class.page(team: team, limit: 2, today: Time.zone.today, status: "valid") },
      members: sql_profile { CareLines::TeamPopulation.members(team: team) }
    }
  end

  it "equipe com 3.000+ pessoas (cadastro, território e pares sem paciente): validade e prévia com consultas e SQL constantes" do
    registry_registration!(household: registry_household!(micro_area: area))
    care_patient!(age: 50, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    neighborhood = care_neighborhood!(unit)
    bulk_registrations!(2, offset: 0)
    bulk_territorial!(2, offset: 0, neighborhood: neighborhood)
    bulk_pairs!(2, offset: 0, neighborhood: neighborhood)
    small = profiles
    bulk_registrations!(1_000, offset: 2)
    bulk_territorial!(1_000, offset: 2, neighborhood: neighborhood)
    bulk_pairs!(1_000, offset: 2, neighborhood: neighborhood)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    big = profiles
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(big).to eq(small)
    expect(described_class.count(team: team, today: Time.zone.today)).to include(valid: 1_003, missing: 2_005)
    expect(Patient.where(cns: valid_cns(10_500)).sole.full_name).to eq("Pessoa 500") # cifra no insert_all
    expect(elapsed).to be < 30
  end
end
