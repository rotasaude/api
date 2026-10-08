# spec/models/ledi_correction_pending_guard_spec.rb
require "rails_helper"

# ADR 0031 (Invariantes; spec §6): nenhuma correção de ficha aceita é enviada
# enquanto o reenvio após aceite não for confirmado (api#41): a linha que
# substitui uma aceita só existe como correction_pending e não sai dele.
RSpec.describe "ledi_outbox correction_pending" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  def entry!(status: "pending", **attrs)
    LediOutboxEntry.create!({ uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "atendimento_individual", competence: "202610",
                              source_type: "Consultation", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
                              status: status, next_attempt_at: Time.current, bytes: "x".b }.merge(attrs))
  end

  # let!: criada fora do savepoint de attempt (lazy, sumiria no rollback dele).
  let!(:accepted) { entry!.tap(&:accept!) }

  it "a correção de uma aceita nasce correction_pending, uma por aceita, e o claim nunca a pega" do
    correction = entry!(status: "correction_pending", source_id: accepted.source_id, replaces_outbox_id: accepted.id)
    expect(LediOutboxEntry.claim!(limit: 10)).to be_empty
    expect(correction.reload.status).to eq("correction_pending")
    expect { attempt { entry!(status: "correction_pending", source_id: accepted.source_id, replaces_outbox_id: accepted.id) } }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "não nasce pending nem vira pending/sending; correction_pending exige a substituída" do
    expect { attempt { entry!(source_id: accepted.source_id, replaces_outbox_id: accepted.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /correction of an accepted ficha stays correction_pending/)
    correction = entry!(status: "correction_pending", source_id: accepted.source_id, replaces_outbox_id: accepted.id)
    expect { attempt { correction.update_columns(status: "pending") } }
      .to raise_error(ActiveRecord::StatementInvalid, /correction of an accepted ficha stays correction_pending/)
    expect { attempt { entry!(status: "correction_pending") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_ledi_outbox_correction/)
    expect { correction.update!(bytes: "y".b) }.not_to raise_error
  end
end
