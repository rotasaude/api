# spec/commands/signatures/run_batch_chain_spec.rb
require "rails_helper"

# Decisão do usuário (cadeia no lote): assinar em ordem cronológica de criação;
# o adendo seguinte leva o hash canônico do anterior do MESMO lote; se o
# anterior falha, o seguinte não é assinado e fica pending com o mesmo motivo.
RSpec.describe "Cadeia no lote" do
  before do
    Current.city = signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
    @signer = stub_signer!
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def addendum!(text)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "adendo #{text} aqui", text: text).payload[:addendum]
  end

  def token
    Signatures::Psc::Token.new(access_token: fake_psc.token_for!(cpf: cpf, scope: "multi_signature"), expires_in: 300,
                               scope: "multi_signature")
  end

  it "dois adendos no mesmo lote (pedidos criados fora de ordem): o segundo leva o hash do primeiro" do
    one = addendum!("um")
    two = addendum!("dois")
    second_request = signature_request!(two, author: doctor) # o pedido do segundo nasce antes
    first_request = signature_request!(one, author: doctor)
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ second_request.id, first_request.id ], token: token, provider: "vidaas")
    expect(result.payload[:record]).to eq(signed: 2, failed: [])
    first = first_request.reload.signature
    second = second_request.reload.signature
    expect(JSON.parse(first.canonical_json).dig("addendum", "previous_sha256"))
      .to eq(Signatures::Canonical.consultation(consultation).sha256)
    expect(JSON.parse(second.canonical_json).dig("addendum", "previous_sha256")).to eq(first.canonical_sha256)
  end

  it "consulta e adendo no mesmo lote: o adendo aponta para a consulta" do
    addendum = addendum!("um")
    requests = [ signature_request!(addendum, author: doctor), signature_request!(consultation, author: doctor) ]
    Signatures::RunBatch.call(user: doctor, request_ids: requests.map(&:id), token: token, provider: "vidaas")
    signed = requests.map { |request| request.reload.signature }
    expect(JSON.parse(signed.first.canonical_json).dig("addendum", "previous_sha256")).to eq(signed.last.canonical_sha256)
  end

  it "o primeiro falha: o segundo não é assinado e fica pending com o mesmo motivo" do
    one = addendum!("um")
    two = addendum!("dois")
    first_request = signature_request!(one, author: doctor)
    second_request = signature_request!(two, author: doctor)
    allow(Consultations::Print).to receive(:addendum).and_wrap_original do |original, addendum, **options|
      raise Consultations::Print::NotPrintable, "teste" if addendum.id == one.id

      original.call(addendum, **options)
    end
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ first_request.id, second_request.id ], token: token, provider: "vidaas")
    expect(result.payload[:record]).to eq(signed: 0, failed: [ { request_id: first_request.id, reason_code: "verification_failed" },
                                                               { request_id: second_request.id, reason_code: "verification_failed" } ])
    expect([ first_request, second_request ].map { |r| r.reload.slice(:status, :reason_code).values }).to all(eq(%w[pending verification_failed]))
    # Falha definitiva (R19): o lote não soma tentativa, como o SignPending#settle.
    expect([ first_request, second_request ].map(&:attempts)).to eq([ 0, 0 ])
    expect(Signature.count).to eq(0)
  end

  it "o primeiro falha depois do PSC (verificação): o segundo também não é gravado" do
    one = addendum!("um")
    two = addendum!("dois")
    first_request = signature_request!(one, author: doctor)
    second_request = signature_request!(two, author: doctor)
    first_json = Signatures::Canonical.addendum(one).json
    allow(@signer).to receive(:verify).and_wrap_original do |original, **options|
      result = original.call(**options)
      options[:document] == first_json ? result.with(status: "invalid", reasons: [ "signature_mismatch" ]) : result
    end
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ first_request.id, second_request.id ], token: token, provider: "vidaas")
    expect(result.payload[:record][:signed]).to eq(0)
    expect(result.payload[:record][:failed].map { |item| item[:reason_code] }.uniq).to eq([ "verification_failed" ])
    # Passageira e não definitiva: soma uma tentativa (como o SignPending#settle).
    expect([ first_request, second_request ].map { |r| r.reload.attempts }).to eq([ 1, 1 ])
    expect(Signature.count).to eq(0)
  end

  it "interruptor desligado quando o lote toca o pedido: volta ao papel na hora (feature_disabled)" do
    request = signature_request!(consultation, author: doctor)
    signature_city!(enabled: false)
    result = Signatures::RunBatch.call(user: doctor, request_ids: [ request.id ], token: token, provider: "vidaas")
    expect(result.reason).to eq(:feature_disabled)
    expect(request.reload).to have_attributes(status: "returned_to_paper", reason_code: "feature_disabled")
  end
end
