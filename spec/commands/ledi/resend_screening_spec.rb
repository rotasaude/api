require "rails_helper"

# ADR 0030 (spec §5): ficha de escuta recusada e corrigida na origem é regerada
# — linha nova com outro uuid e replaces_outbox_id; a antiga fica recusada.
# Review Focus 5: regenerar duas vezes a mesma recusada → not_rejected.
RSpec.describe Ledi::Resend, "fonte Screening" do
  let(:city) { ledi_ready!(register_test_city!, pec_url: "https://pec.a.test", record_mode: "record") }
  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:by) { ledi_admin! }

  around { |ex| CityConnection.with(city) { ex.run } }
  before do
    # O harness põe Current.city = TEST_CITY_A (City sem id); a regeneração lê
    # o interruptor da cidade corrente, como na requisição (City do catálogo).
    Current.city = city
    ciap2_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
    exportable_unit!(unit, nurse)
  end

  let(:rejected) do
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    Ledi::ScreeningFicha.generate(started.reload, city: city)
    LediOutboxEntry.sole.tap { |e| e.reject!([ { "field" => "cpfCidadao", "code" => "invalid" } ]) }
  end

  it "regera da origem: nova pendente com outro uuid e o vínculo; a recusada fica; de novo → not_rejected" do
    fresh = described_class.call(entry: rejected, by: by)
    expect(fresh.id).not_to eq(rejected.id)
    expect(fresh).to have_attributes(status: "pending", replaces_outbox_id: rejected.id, source_id: rejected.source_id)
    expect(fresh.uuid).not_to eq(rejected.uuid)
    expect(rejected.reload.status).to eq("rejected")
    expect { described_class.call(entry: rejected.reload, by: by) }.to raise_error(described_class::NotRejected)
    expect(LediOutboxEntry.where(source_id: rejected.source_id).count).to eq(2)
  end

  it "identificação quebrada desde então: 'não gerada' registrada e NotRegenerated; exportação inutilizável: ExportUnusable" do
    entry = rejected
    unit.update!(cnes: nil)
    expect { described_class.call(entry: entry, by: by) }.to raise_error(described_class::NotRegenerated)
    expect(LediGenerationFailure.unresolved.sole.reason_codes).to eq(%w[unit_without_cnes])
    unit.update!(cnes: "1234567")
    ledi_off!(city)
    expect { described_class.call(entry: entry.reload, by: by) }.to raise_error(described_class::ExportUnusable)
    expect(entry.reload.status).to eq("rejected")
  end
end
