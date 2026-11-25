require "rails_helper"

# Módulo 27b, Task 11 (contrato §3; Valor 6; R10, R19): o job de toda hora (no
# minuto 7) fecha a janela (a parte de R não enviada, ou recusada e não
# reenviada, vira `lost` às 00:00 de R+2; a parte em processamento segue, Q31),
# purga todo payload 30 dias depois do envio (ou da criação, se nunca saiu; Q30)
# e, a partir da 1h no fuso da cidade, monta
# R = ontem com os domínios ligados até o fim de R. A limpeza roda com o
# `bnafar` desligado; só a montagem exige o interruptor utilizável.
RSpec.describe Bnafar::DailyJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  let(:today) { Time.zone.today }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }

  def at(date, hour, min = 0) = date.in_time_zone.change(hour: hour, min: min)
  def run!(time) = travel_to(time) { described_class.perform_now }

  before do
    bnafar_on!(city, since: at(today - 10, 8))
    losartana.update_columns(vmp_code: "@brasil1000")
    travel_to(at(today - 2, 8)) do
      bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "10"), ampp_code: "@brasil20038375080")
    end
  end

  it "às 00:40 local não monta; às 01:07 monta R = ontem" do
    run!(at(today, 0, 40))
    expect(BnafarSubmission.count).to eq(0)

    run!(at(today, 1, 7))
    expect(BnafarSubmission.pluck(:reference_on, :subject, :environment))
      .to contain_exactly([ today - 1, "position", "production" ], [ today - 1, "exit", "production" ])
    expect(BnafarSubmission.find_by!(subject: "position").records.count).to eq(1)

    expect { run!(at(today, 2, 7)) }.not_to(change { [ BnafarSubmission.count, BnafarRecord.count ] })
  end

  it "domínio ligado hoje não entra em R" do
    CityFeature.where(city_id: city.id, key: "bnafar_medications").update_all(changed_at: at(today, 0, 30))
    run!(at(today, 1, 7))
    expect(BnafarSubmission.count).to eq(0)
  end

  it "`bnafar` desligado → nada novo" do
    Platform::Features.set!(city: city, key: "bnafar", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    run!(at(today, 1, 7))
    expect(BnafarSubmission.count).to eq(0)
  end

  it "remessa de anteontem com recusa → lost (00:00 de R+2); a de ontem não; a de 29 dias com delete continua finished (R10)" do
    old = rejected_submission!(today - 2)
    recent = rejected_submission!(today - 1)
    month = BnafarSubmission.create!(reference_on: today - 29, subject: "exit", environment: "production", status: "finished",
                                     finished_at: 28.days.ago)
    BnafarBatch.create!(bnafar_submission: month, operation: "delete", status: "failed", finished_at: 1.day.ago)

    run!(at(today, 0, 7))
    expect(old.reload.status).to eq("lost")
    expect(recent.reload.status).to eq("finished")
    expect(month.reload.status).to eq("finished")
    expect(DomainEvent.where(name: "bnafar_submission.lost").map(&:payload)).to eq([ { "bnafar_submission_id" => old.id } ])
  end

  it "remessa de anteontem ainda queued → lost e o lote post queued vira failed" do
    stuck = BnafarSubmission.create!(reference_on: today - 2, subject: "position", environment: "production", status: "queued")
    batch = BnafarBatch.create!(bnafar_submission: stuck, operation: "post", status: "queued")

    run!(at(today, 0, 7))
    expect(stuck.reload.status).to eq("lost")
    expect(batch.reload).to have_attributes(status: "failed", last_error: "window_closed")
  end

  it "`bnafar` desligado → payload aceito há 31 dias vira NULL; o de 29 dias fica (R19)" do
    Platform::Features.set!(city: city, key: "bnafar", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    old = accepted_record!(accepted_at: at(today, 9) - 31.days)
    fresh = accepted_record!(accepted_at: at(today, 9) - 29.days)

    run!(at(today, 9, 7))
    expect(BnafarRecord.where(id: old.id).pick(:payload)).to be_nil
    expect(BnafarRecord.where(id: fresh.id).pick(:payload)).to be_present
  end

  it "Q30: recusado enviado há 31 dias → payload NULL; nunca enviado criado há 31 dias → NULL; os metadados ficam" do
    submission = BnafarSubmission.create!(reference_on: today - 32, subject: "position", environment: "production", status: "lost")
    batch = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "finished", finished_at: 31.days.ago, protocol: 4242)
    rejected = BnafarRecord.create!(bnafar_submission: submission, bnafar_batch: batch, origin_code: SecureRandom.uuid, subject: "position",
                                    stock_location_id: central.id, item_key: "medication:x", payload: "{\"x\":1}", status: "rejected",
                                    error_codes: [ "MSG12" ], sent_at: at(today, 9) - 31.days)
    unsent = travel_to(at(today, 9) - 31.days) do
      BnafarRecord.create!(bnafar_submission: submission, origin_code: SecureRandom.uuid, subject: "position", stock_location_id: central.id,
                           item_key: "medication:y", payload: "{\"y\":1}")
    end
    young = travel_to(at(today, 9) - 29.days) do
      BnafarRecord.create!(bnafar_submission: submission, origin_code: SecureRandom.uuid, subject: "position", stock_location_id: central.id,
                           item_key: "medication:z", payload: "{\"z\":1}")
    end

    run!(at(today, 9, 7))
    expect(BnafarRecord.where(id: [ rejected.id, unsent.id ]).pluck(:payload)).to eq([ nil, nil ])
    expect(BnafarRecord.where(id: young.id).pick(:payload)).to be_present
    expect(rejected.reload).to have_attributes(status: "rejected", error_codes: [ "MSG12" ], sent_at: be_present)
    expect(batch.reload.protocol).to eq(4242)
  end

  it "Q31: remessa finished com uma parte que nunca saiu (window_closed) → lost" do
    submission = BnafarSubmission.create!(reference_on: today - 2, subject: "position", environment: "production", status: "finished",
                                          finished_at: Time.current)
    sent = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "finished", finished_at: Time.current)
    BnafarRecord.create!(bnafar_submission: submission, bnafar_batch: sent, origin_code: SecureRandom.uuid, subject: "position",
                         stock_location_id: central.id, item_key: "medication:x", payload: "{}", status: "accepted", accepted_at: Time.current)
    unsent = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "failed", last_error: "window_closed",
                                 finished_at: Time.current)
    BnafarRecord.create!(bnafar_submission: submission, bnafar_batch: unsent, origin_code: SecureRandom.uuid, subject: "position",
                         stock_location_id: central.id, item_key: "medication:y", payload: "{}")

    run!(at(today, 0, 7))
    expect(submission.reload.status).to eq("lost")
  end

  it "Q31: parte post em processing (ou em sending) às 00:07 de R+2 → a remessa não vira lost" do
    processing = BnafarSubmission.create!(reference_on: today - 2, subject: "position", environment: "production", status: "processing")
    BnafarBatch.create!(bnafar_submission: processing, operation: "post", status: "processing", protocol: 77)
    BnafarBatch.create!(bnafar_submission: processing, operation: "post", status: "queued")
    sending = BnafarSubmission.create!(reference_on: today - 2, subject: "exit", environment: "production", status: "sending")
    BnafarBatch.create!(bnafar_submission: sending, operation: "post", status: "sending")

    run!(at(today, 0, 7))
    expect([ processing.reload.status, sending.reload.status ]).to eq(%w[processing sending])
    expect(processing.batches.where(status: "queued")).to be_empty # a parte que não saiu não sai mais
    expect(DomainEvent.where(name: "bnafar_submission.lost")).to be_empty
  end

  it "Q31: lote post queued sob remessa já lost (sobra de um sending que voltou) → failed na varredura" do
    lost = BnafarSubmission.create!(reference_on: today - 3, subject: "position", environment: "production", status: "lost")
    residue = BnafarBatch.create!(bnafar_submission: lost, operation: "post", status: "queued")

    run!(at(today, 0, 7))
    expect(residue.reload).to have_attributes(status: "failed", last_error: "window_closed")
  end

  it "é recorrente de hora em hora no minuto 7, na fila housekeeping" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    expect(recurring.dig("production", "bnafar_daily"))
      .to include("class" => "Bnafar::DailyJob", "queue" => "housekeeping", "schedule" => "every hour at minute 7")
  end

  def rejected_submission!(reference_on)
    submission = BnafarSubmission.create!(reference_on: reference_on, subject: "position", environment: "production", status: "finished",
                                          finished_at: Time.current)
    batch = BnafarBatch.create!(bnafar_submission: submission, operation: "post", status: "finished", finished_at: Time.current)
    BnafarRecord.create!(bnafar_submission: submission, bnafar_batch: batch, origin_code: SecureRandom.uuid, subject: "position",
                         stock_location_id: central.id, item_key: "medication:x", payload: "{}", status: "rejected", error_codes: [ "MSG09" ])
    submission
  end

  def accepted_record!(accepted_at:)
    submission = BnafarSubmission.find_or_create_by!(reference_on: accepted_at.to_date - 1, subject: "exit", environment: "production") do |s|
      s.status = "finished"
      s.finished_at = accepted_at
    end
    BnafarRecord.create!(bnafar_submission: submission, origin_code: SecureRandom.uuid, subject: "exit", stock_location_id: central.id,
                         item_key: "medication:x", payload: "{\"x\":1}", status: "accepted", accepted_at: accepted_at, sent_at: accepted_at,
                         bnafar_code: 77)
  end
end
