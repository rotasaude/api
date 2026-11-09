require "rails_helper"

# Módulo 32a (plano, Desvio 1 e Valor fixado 5; Review Focus 2): a senha da
# sala de espera conta por unidade e dia LOCAL (`ticket_on`), com o prefixo da
# unidade.
RSpec.describe Attendances::Ticket do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { clinical_city! }
  let(:upa) { create_unit("UPA Senha", kind: "upa") }

  # Chegada na UPA com a senha emitida agora (o Urgency::Arrive da Task 6 faz
  # o mesmo: senha e linha na mesma transação, sob a unidade travada).
  def walk_in_with_ticket!(unit)
    @seq = (@seq || 0) + 1
    patient = Patient.create!(cpf: valid_cpf(@seq), full_name: "Paciente #{@seq}", birth_date: "1980-01-01", sex: "female")
    ApplicationRecord.transaction do
      HealthUnit.lock_active!(unit.id)
      ticket, day = described_class.issue(unit)
      Attendance.create!(origin_kind: "walk_in", patient: patient, health_unit: unit, checked_in_by_user: reception!,
                         checked_in_at: Time.current, check_in_method: "urgency_reception", ticket: ticket, ticket_on: day)
    end
  end

  it "conta por unidade e dia LOCAL; 23:59 é do dia, 00:01 recomeça" do
    travel_to(Time.zone.parse("2026-11-05 23:59")) do
      # 23:59 em São Paulo já é 02:59 do dia 6 em UTC.
      expect(Time.current.utc.to_date).to eq(Date.new(2026, 11, 6))
      2.times { |i| walk_in_with_ticket!(upa) }
      expect(described_class.issue(upa)).to eq([ "U-003", Date.new(2026, 11, 5) ])
    end
    travel_to(Time.zone.parse("2026-11-06 00:01")) { expect(described_class.issue(upa)).to eq([ "U-001", Date.new(2026, 11, 6) ]) }
  end

  it "o prefixo é o da unidade; a UBS nasce com A" do
    expect(described_class.issue(create_unit("UBS Senha")).first).to eq("A-001")
  end

  it "a contagem é por unidade; o dia vem do `at` informado" do
    walk_in_with_ticket!(upa)
    other = create_unit("UPA Outra", kind: "upa")
    other.update!(ticket_prefix: "UB")
    expect(described_class.issue(other)).to eq([ "UB-001", Date.current ])
    expect(described_class.issue(upa, at: 1.day.from_now)).to eq([ "U-001", Date.current + 1 ])
  end
end

# Review Focus 2: duas chegadas simultâneas na mesma UPA nunca repetem a senha.
# A segunda espera a primeira (trava consultiva por unidade, liberada no
# commit) e conta a senha que a primeira acabou de gravar — sem 409 nem
# RecordNotUnique. Threads reais contra TEST_CITY_A (sem fixture
# transacional), como spec/commands/attendances/call_next_concurrency_spec.rb.
RSpec.describe Attendances::Ticket, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { { patients: [], attendances: [] } }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        ids[:admin] = User.create!(email_address: "rec-#{tag}@c.gov.br", password: "senha-segura-123").id
        ids[:unit] = HealthUnit.create!(name: "UPA Senha #{tag}", kind: "upa").id
        2.times do |i|
          ids[:patients] << Patient.create!(cpf: CampaignHistory.cpf_for("senha-#{tag}-#{i}"), full_name: "P #{i}",
                                            birth_date: "1980-01-01", sex: "female").id
        end
      end
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        Attendance.where(health_unit_id: ids[:unit]).delete_all
        Patient.where(id: ids[:patients]).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit))
  end

  def arrive(patient_id, hold: nil)
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        ApplicationRecord.transaction do
          unit = HealthUnit.lock_active!(ids[:unit])
          ticket, day = Attendances::Ticket.issue(unit)
          a = Attendance.create!(origin_kind: "walk_in", patient_id: patient_id, health_unit: unit,
                                 checked_in_by_user_id: ids[:admin], checked_in_at: Time.current,
                                 check_in_method: "urgency_reception", ticket: ticket, ticket_on: day)
          if hold
            hold << true
            release.pop(timeout: 10) or raise "timeout esperando release"
          end
          a.ticket
        end
      end
    end
  end

  it "a segunda chegada espera a primeira e leva a senha seguinte" do
    holding = Queue.new
    first = Queue.new
    threads << holder = Thread.new { first << arrive(ids[:patients][0], hold: holding) }
    holding.pop(timeout: 5) or raise "a primeira chegada não segurou a senha"

    second = Queue.new
    threads << waiter = Thread.new { second << arrive(ids[:patients][1]) }
    # A segunda está parada na trava da primeira, não numa senha repetida.
    expect(waiter.join(1)).to be_nil

    release << true
    expect(holder.join(5)).to be(holder)
    expect(waiter.join(5)).to be(waiter)
    expect([ first.pop(timeout: 1), second.pop(timeout: 1) ]).to eq(%w[U-001 U-002])
  end
end
