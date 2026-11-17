require "rails_helper"

# Módulo 35a, Task 11 (ADR 0054; contrato §8; Q8, Q13(6)): o número do caso
# é a sequência da cidade, dado na inserção como o maior + 1 sob a trava
# consultiva da proposta (sem buraco quando a proposta volta atrás) e nunca
# muda, nem depois de mover o caso.
RSpec.describe VectorControl::Blocks::Propose, type: :model do
  let!(:city) { block_city! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:one) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:far) { city_block!(neighborhood: neighborhood, number: "40") }
  let(:parameters) { VectorControl::Parameters.current.values }

  after { Current.reset }

  def propose(notification) = described_class.call(notification: notification, parameters: parameters)

  it "número da cidade: maior + 1, sem buraco quando a proposta volta atrás" do
    first = arbovirus_case!(patient: block_case_patient!(block: one))
    expect(propose(first)).to be_ok

    rolled_back = arbovirus_case!(patient: block_case_patient!(block: far))
    ApplicationRecord.transaction(requires_new: true) do
      expect(propose(rolled_back)).to be_ok
      raise ActiveRecord::Rollback
    end
    expect(TransmissionBlockCase.find_by(disease_notification_id: rolled_back.id)).to be_nil

    third = arbovirus_case!(patient: block_case_patient!(block: far))
    expect(propose(third)).to be_ok
    expect(TransmissionBlockCase.order(:number).pluck(:number)).to eq([ 1, 2 ])
  end

  it "a proposta devolve o bloqueio e o caso; trava consultiva fixa no SQL, sem dado do caso" do
    notification = arbovirus_case!(patient: block_case_patient!(block: one))
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { propose(notification) }

    expect(result).to be_ok
    expect(result.payload[:case]).to eq(TransmissionBlockCase.find_by!(disease_notification_id: notification.id))
    expect(result.payload[:block]).to eq(result.payload[:case].transmission_block)
    expect(sql).to include("SELECT pg_advisory_xact_lock(hashtextextended('vector_control:transmission_blocks', 0))")
  end
end
