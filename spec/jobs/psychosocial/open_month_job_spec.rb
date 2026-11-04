require "rails_helper"

# Módulo 31 (contrato §6; plano, Desvio 6): a continuidade da RAAS — todo dia,
# por cidade com `psychosocial_care` utilizável, o registro `open` do mês
# corrente para toda matrícula aberta (idempotente). Mês já fechado no CAPS
# não ganha registro. Log só com a contagem.
RSpec.describe Psychosocial::OpenMonthJob do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 12, 1, 1, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:december) { Date.new(2026, 12, 1) }
  let(:open_enrollment) { enrollment!(caps, started_on: Date.new(2026, 11, 3)) }
  let(:closed_enrollment) do
    enrollment!(caps, started_on: Date.new(2026, 11, 3)).tap do |e|
      e.update!(closed_on: Date.new(2026, 11, 20), destination: "01", closed_by_user: e.reference_user)
    end
  end

  def december_records = PsychosocialMonthlyRecord.where(month: december)

  it "no dia 1º abre o mês para a matrícula aberta e não para a encerrada; duas execuções → um registro" do
    open_enrollment && closed_enrollment
    expect { described_class.perform_now; described_class.perform_now }.to change { december_records.count }.by(1)
    expect(december_records.sole).to have_attributes(psychosocial_enrollment_id: open_enrollment.id, health_unit_id: caps.id,
                                                     status: "open", homeless: nil, snapshot: nil)
  end

  it "não duplica o registro que a matrícula ou a ação já abriu" do
    Psychosocial::MonthlyRecords.ensure!(open_enrollment, december)
    expect { described_class.perform_now }.not_to(change { december_records.count })
  end

  it "mês já fechado no CAPS não ganha registro" do
    open_enrollment
    PsychosocialMonthClosure.create!(health_unit: caps, month: december, closed_by_user: open_enrollment.reference_user, closed_at: Time.current)
    expect { described_class.perform_now }.not_to(change { december_records.count })
  end

  it "com o interruptor desligado, nada" do
    open_enrollment
    Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    expect { described_class.perform_now }.not_to(change { december_records.count })
  end

  it "o log só leva a contagem" do
    open_enrollment
    log = capture_log { described_class.perform_now }
    expect(log).to include("opened=1")
    expect(log).not_to include(open_enrollment.patient.display_name)
  end

  it "está agendado todo dia à 1h no fuso de São Paulo, na fila housekeeping" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("default").fetch("psychosocial_open_month")
    expect(task).to include("class" => "Psychosocial::OpenMonthJob", "queue" => "housekeeping",
                            "schedule" => "every day at 1am America/Sao_Paulo")
  end
end
