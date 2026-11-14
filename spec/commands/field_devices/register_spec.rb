require "rails_helper"

# Módulo 24c (ADR 0053; contrato §1, Q16, Q17): cadastrar um aparelho no lugar
# de outro. A substituição revoga o antigo (motivo replaced, com autor) e cria
# o novo na mesma transação; só um aparelho ATIVO do próprio usuário pode ser
# substituído; o limite de ativos não conta o substituído.
RSpec.describe FieldDevices::Register, type: :model do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:colleague) { field_agent!(team: team) }

  def register(user = acs, name: "Tablet novo", **opts) = described_class.call(user: user, name: name, **opts)
  def device!(user = acs, name: "Tablet") = register(user, name: name).payload.fetch(:device)
  def failure(result) = [ result.reason, result.details ]
  def events(name) = DomainEvent.where(name: "field_device.#{name}").order(:occurred_at)

  it "sem substituição, nada muda: cria e devolve replaced nil" do
    result = register
    expect(result).to be_ok
    expect(result.payload.keys).to match_array(%i[device token replaced])
    expect(result.payload[:replaced]).to be_nil
  end

  it "com 3 ativos, substituir um revoga o antigo (replaced, com autor) e mantém 3 ativos" do
    old, = Array.new(3) { |i| device!(name: "Tablet #{i}") }
    expect(failure(register)).to eq([ :device_limit, {} ])

    result = register(replaces_device_id: old.id)
    expect(result).to be_ok
    expect(result.payload[:replaced]).to eq(old)
    expect(old.reload).to have_attributes(revoked_reason: "replaced", revoked_by_user_id: acs.id)
    expect(old.revoked_at).to be_present
    expect(FieldDevice.active.where(user: acs).count).to eq(3)
    expect(FieldDevice.active.where(user: acs)).to include(result.payload[:device])
  end

  it "aparelho de outro usuário, revogado ou inexistente → invalid_request no replaces_device_id, nada revogado nem criado" do
    mine = device!
    theirs = device!(colleague)
    revoked_by_owner = device!(name: "Antigo")
    FieldDevices::Revoke.call(revoked_by_owner, by: acs, reason: "user")
    suspended = device!(name: "Suspenso")
    FieldDevices::Revoke.call(suspended, by: nil, reason: "membership_ended")
    count = FieldDevice.count

    [ theirs.id, revoked_by_owner.id, suspended.id, SecureRandom.uuid ].each do |id|
      expect(failure(register(replaces_device_id: id))).to eq([ :invalid_request, { path: "replaces_device_id" } ])
    end
    expect(FieldDevice.count).to eq(count)
    expect([ mine, theirs ].map { _1.reload.revoked? }).to eq([ false, false ])
    expect(suspended.reload.revoked_reason).to eq("membership_ended")
  end

  it "o que não é UUID → invalid_request, antes de travar ou revogar" do
    device!
    [ "abc", 12, [], "" ].each do |value|
      expect(failure(register(replaces_device_id: value))).to eq([ :invalid_request, { path: "replaces_device_id" } ])
    end
    expect(FieldDevice.active.count).to eq(1)
  end

  it "nome inválido é recusado antes de olhar o aparelho substituído" do
    old = device!
    expect(failure(register(name: " ", replaces_device_id: old.id))).to eq([ :invalid_request, { path: "name" } ])
    expect(old.reload).not_to be_revoked
  end

  it "falha ao criar desfaz a revogação" do
    old = device!
    allow(FieldDevice).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
    expect { register(replaces_device_id: old.id) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(old.reload).not_to be_revoked
    expect(events("revoked")).to be_empty
  end

  it "eventos: revogação com o motivo replaced e o cadastro novo, só ids" do
    old = device!
    result = register(replaces_device_id: old.id)
    expect(events("revoked").sole.payload).to eq("field_device_id" => old.id, "user_id" => acs.id, "reason" => "replaced")
    expect(events("registered").order(:occurred_at).last.payload)
      .to eq("field_device_id" => result.payload[:device].id, "user_id" => acs.id)
  end
end
