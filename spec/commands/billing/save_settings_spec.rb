require "rails_helper"

# Revisão final, T10: a corrida da linha única (RecordNotUnique) tenta de
# novo no máximo uma vez — nunca em laço.
RSpec.describe Billing::SaveSettings do
  before { billing_city! }

  let(:admin) { lab_admin! }
  let(:params) do
    { "origin_name" => "SMS Curitiba", "origin_cnpj" => "11222333000181", "destination_body" => "Secretaria Municipal de Saude",
      "management" => "M" }
  end

  def failing_lock(times)
    attempts = 0
    allow(BillingSetting).to receive(:lock).and_wrap_original do |original, *args|
      attempts += 1
      raise ActiveRecord::RecordNotUnique, "idx_billing_settings_singleton" if attempts <= times

      original.call(*args)
    end
    -> { attempts }
  end

  it "uma corrida: tenta de novo uma vez e grava" do
    attempts = failing_lock(1)
    expect(described_class.call(params: params, by: admin)).to be_ok
    expect(attempts.call).to eq(2)
    expect(BillingSetting.count).to eq(1)
  end

  it "corrida repetida: desiste depois da segunda tentativa" do
    attempts = failing_lock(3)
    expect { described_class.call(params: params, by: admin) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(attempts.call).to eq(2)
    expect(BillingSetting.count).to eq(0)
  end
end
