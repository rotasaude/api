require "rails_helper"

# Review Focus 4: o faturista fecha enquanto o profissional grava um
# procedimento da mesma competência. A gravação espera a trava da
# competência (FOR SHARE × FOR UPDATE) e, fechada, cai na competência
# seguinte, atrasada — nunca fica numa competência fechada fora do arquivo.
RSpec.describe "Fechamento × gravação ao mesmo tempo" do
  self.use_transactional_tests = false

  let(:ids) { {} }
  let(:threads) { [] }
  let(:release) { Queue.new }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def insert(at)
    unit = HealthUnit.find(ids[:unit])
    Billing::Record.insert!(patient: Patient.find(ids[:patient]), establishment: Billing::Establishment.for_unit(unit),
                            professional: User.find(ids[:doctor]), cbo_code: "225125", source: "manual", performed_on: at,
                            sigtap_code: "0301100012", quantity: 1, cid10: nil, character: "elective", recorded_by: User.find(ids[:doctor]))
  end

  before do
    allow(Billing::Critic).to receive(:call).and_return(
      Billing::Critic::Outcome.new(instrument: "bpa_c", billable: true, reasons: [], sigtap_competence: nil, fallback: false, label: nil)
    )
    in_city do
      tag = SecureRandom.hex(4)
      admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
      doctor = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
      unit = HealthUnit.create!(name: "UPA #{tag}", kind: "upa", cnes: format("%07d", SecureRandom.random_number(9_000_000) + 1_000_000))
      patient = Patient.create!(cpf: CampaignHistory.cpf_for("faturamento-#{tag}"), full_name: "Maria Aparecida da Silva",
                                birth_date: "1980-05-10", sex: "female")
      ids[:settings_created] = BillingSetting.current.nil?
      if ids[:settings_created]
        BillingSetting.create!(origin_name: "SMS", origin_cnpj: "11222333000181", destination_body: "SMS", management: "M", updated_by_user: admin)
      end
      ids.merge!(admin: admin.id, doctor: doctor.id, unit: unit.id, patient: patient.id)
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        procedures = PerformedProcedure.where(health_unit_id: ids[:unit])
        periods = BillingPeriod.where(health_unit_id: ids[:unit])
        exports = BillingExport.where(billing_period_id: periods.select(:id))
        refs = procedures.pluck(:id) + periods.pluck(:id) + exports.pluck(:id)
        %w[performed_procedure_id billing_period_id billing_export_id].each do |key|
          DomainEvent.where("payload->>'#{key}' IN (?)", refs.presence || [ "" ]).delete_all
        end
        procedures.delete_all
        exports.delete_all
        periods.delete_all
        BillingSetting.delete_all if ids[:settings_created]
        Patient.where(id: ids[:patient]).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :doctor, :unit))
  end

  it "a gravação espera o fechamento e cai na competência seguinte, atrasada" do
    today = Date.current
    first = in_city { insert(today) }
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "billing_period.closed"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    closed = Queue.new
    threads << (holder = Thread.new do
      closed << in_city { Billing::Close.call(period: BillingPeriod.find(first.billing_period_id), by: User.find(ids[:admin])) }
    end)
    holding.pop(timeout: 5) or raise "o fechamento não segurou a trava"

    recorded = Queue.new
    threads << Thread.new { recorded << in_city { insert(today) } }
    expect(wait_for_lock_wait).to be(true)
    release << true

    expect(closed.pop(timeout: 10)).to be_ok
    late = recorded.pop(timeout: 10)
    expect(late).to have_attributes(late: true, billing_competence: today.next_month.strftime("%Y%m"))
    in_city do
      expect(first.reload.billing_export_id).to be_present
      expect(late.reload.billing_export_id).to be_nil
    end
  end
end
