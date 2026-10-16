require "rails_helper"

# Perfil rotasaude.lab.hl7.v1 (Divergências D1, D2; B22, B25, B26): lê os
# exemplos do contracts e escreve respostas com a mesma estrutura.
RSpec.describe "Lab::Hl7" do
  def fixture(name) = File.binread(Rails.root.join("spec/fixtures/lab/#{name}"))
  def segments(text) = text.split("\r").map { |s| s.split("|", -1) }
  def parse(name) = Lab::Hl7::Message.parse(fixture(name))
  let(:now) { Time.zone.parse("2026-10-15 15:00:01") }
  def error(code, location) = Lab::Hl7::Builder::Error.new(code: code, location: location)

  it "lê OUL^R22: tipo, controle, versão, grupos SPM/OBR/OBX" do
    message = parse("oul-r22.hl7")
    expect([ message.type, message.control_id, message.version ]).to eq([ "OUL^R22^OUL_R22", "M0001", "2.5.1" ])
    specimen = message.specimens.sole
    expect(message.field(specimen.spm, 2, 1)).to eq("0000012301")
    expect(message.barcode(specimen)).to eq("0000012301")
    order = specimen.orders.sole
    expect(message.field(order.obr, 4, 1)).to eq("GLI")
    obx = order.results.sole
    expect([ message.field(obx.segment, 3, 1), message.field(obx.segment, 5, 1), message.field(obx.segment, 6, 1), obx.index ])
      .to eq([ "glicose", "98", "mg/dL", 1 ])
  end

  it "lê QBP^Q11" do
    message = parse("qbp-q11.hl7")
    expect(message.type).to eq("QBP^Q11^QBP_Q11")
    expect(message.field(message.first("QPD"), 2)).to eq("T0001")
    expect(message.field(message.first("QPD"), 3)).to eq("0000012301")
  end

  it "aceita OUL^R22 sem SPM-4 (B25)" do
    message = parse("oul-r22-without-spm4.hl7")
    expect(message.field(message.specimens.sole.spm, 4)).to eq("")
    expect(message.structure_errors).to be_empty
  end

  it "aceita \\n e \\r\\n, desfaz escapes e recusa o que não é HL7" do
    base = fixture("oul-r22.hl7").sub("|98|") { "|5\\S\\3|" }
    [ base.tr("\r", "\n"), base.gsub("\r", "\r\n") ].each do |raw|
      message = Lab::Hl7::Message.parse(raw)
      expect(message.field(message.specimens.sole.orders.sole.results.sole.segment, 5)).to eq("5^3")
    end
    [ "", "PID|1", "MSH|^~\\$|x", "MSH|^~\\&|a\rxx\r", "\xFF\xFE".b ].each do |raw|
      expect { Lab::Hl7::Message.parse(raw) }.to raise_error(Lab::Hl7::Invalid), raw.inspect
    end
  end

  it "Invalid leva só o código, nunca a mensagem" do
    error = begin
      Lab::Hl7::Message.parse("PID|segredo123")
    rescue Lab::Hl7::Invalid => e
      e
    end
    expect(error.code).to eq("invalid_message")
    expect(error.message).not_to include("segredo123")
  end

  it "junta todos os problemas de estrutura sem parar no primeiro (B26)" do
    raw = "MSH|^~\\&|a|b|ROTA-SAUDE|c|20261015||OUL^R22^OUL_R22|M9|P|2.5.1\rSPM|1\rOBR|1|||\rOBX|1|NM|||\rOBX|2|NM|x^y^99RSL||\r"
    errors = Lab::Hl7::Message.parse(raw).structure_errors
    expect(errors.map { |e| [ e.code, e.location ] }).to eq([
      [ "unknown_barcode", "SPM^1^2" ], [ "exam_not_in_version", "OBR^1^4" ],
      [ "unknown_analyte", "OBX^1^3" ], [ "invalid_value", "OBX^1^5" ], [ "invalid_value", "OBX^2^5" ]
    ])
    expect(parse("oul-r22-two-refusals.hl7").structure_errors).to be_empty
  end

  it "escreve ACK AA/AE (um ERR) e AE com dois ERR na estrutura dos exemplos" do
    request = parse("oul-r22.hl7")
    aa = Lab::Hl7::Builder.ack(request: request, code: "AA", city_slug: "curitiba", now: now)
    expect(segments(aa)[1..]).to eq(segments(fixture("ack-aa.hl7"))[1..])
    ae = Lab::Hl7::Builder.ack(request: request, code: "AE", city_slug: "curitiba", now: now,
                               errors: [ error("unknown_analyte", "OBX^1^3") ])
    expected = segments(fixture("ack-ae.hl7"))
    got = segments(ae)
    expect(got.map(&:first)).to eq(%w[MSH MSA ERR])
    expect(got[0].values_at(0, 1, 2, 3, 4, 5, 8, 10, 11)).to eq(expected[0].values_at(0, 1, 2, 3, 4, 5, 8, 10, 11))
    expect(got[0][6]).to eq("20261015150001")
    expect(got[1..]).to eq(expected[1..])
    two = Lab::Hl7::Builder.ack(request: parse("oul-r22-two-refusals.hl7"), code: "AE", city_slug: "curitiba", now: now,
                                errors: [ error("out_of_entry_range", "OBX^1^5"), error("unknown_analyte", "OBX^2^3") ])
    expect(segments(two)[1..]).to eq(segments(fixture("ack-ae-two-errors.hl7"))[1..])
    ar = Lab::Hl7::Builder.ack(request: request, code: "AR", city_slug: "curitiba", now: now,
                               errors: [ error("unsupported_version", "MSH^1^12") ])
    expect(segments(ar)[1..]).to eq(segments(fixture("ack-ar.hl7"))[1..])
    expect(ae).to end_with("\r")
  end

  it "escreve RSP AE com ERR e RSP OK com SPM/ORC/OBR" do
    query = parse("qbp-q11.hl7")
    nf = Lab::Hl7::Builder.rsp(request: query, code: "AE", city_slug: "curitiba", query_tag: "T0001", barcode: "0000012301", now: now,
                               errors: [ error("unknown_barcode", "QPD^1^3") ])
    expect(segments(nf)[1..]).to eq(segments(fixture("rsp-k11-unknown-barcode.hl7"))[1..])

    version = Struct.new(:instrument_test_code, :lab_exam)
    exam = Struct.new(:name)
    item = Struct.new(:id, :lab_exam_version)
    sample = Struct.new(:barcode, :material, :collected_at)
    id = "8f9a2a5e-1c2b-4f6d-9a11-2c3d4e5f6a7b"
    ok = Lab::Hl7::Builder.rsp(request: query, code: "AA", city_slug: "curitiba", query_tag: "T0001", barcode: "0000012301", now: now,
                               sample: sample.new("0000012301", "Soro", Time.zone.parse("2026-10-15 09:00:00")),
                               items: [ item.new(id, version.new("GLI", exam.new("Glicose"))) ])
    expect(segments(ok)[1..]).to eq(segments(fixture("rsp-k11.hl7"))[1..])
    empty = Lab::Hl7::Builder.rsp(request: query, code: "AA", city_slug: "curitiba", query_tag: "T0001", barcode: "0000012301", now: now,
                                  sample: sample.new("0000012301", "Soro", nil), items: [])
    expect(segments(empty).map(&:first)).to eq(%w[MSH MSA QAK QPD])
    expect(segments(empty)[2][2]).to eq("NF")
  end

  it "material_key (B28) e escape de delimitadores" do
    expect(Lab::Hl7::Builder.material_key("Sangue total (EDTA)")).to eq("sangue_total_edta")
    expect(Lab::Hl7::Builder.material_key("Urina de 24 h / Açúcar")).to eq("urina_de_24_h_acucar")
    expect(Lab::Hl7::Builder.escape("a|b^c&d~e\\f")).to eq("a\\F\\b\\S\\c\\T\\d\\R\\e\\E\\f")
  end

  describe "injection (fix round 1)" do
    let(:oul) { fixture("oul-r22.hl7") }

    it "I1: MSH-11 vem de lista (P, D, T), nunca do remetente" do
      request = Lab::Hl7::Message.parse(oul.sub("|P|2.5.1") { "|P\\F\\INJ|2.5.1" })
      out = Lab::Hl7::Builder.ack(request: request, code: "AA", city_slug: "curitiba", now: now)
      expect(segments(out)[0].size).to eq(12)
      expect(segments(out)[0][10]).to eq("P")
      t = Lab::Hl7::Message.parse(oul.sub("|P|2.5.1") { "|T|2.5.1" })
      expect(segments(Lab::Hl7::Builder.ack(request: t, code: "AA", city_slug: "c", now: now))[0][10]).to eq("T")
    end

    it "I2: CR/LF em texto nosso nunca abre segmento" do
      version = Struct.new(:instrument_test_code, :lab_exam)
      item = Struct.new(:id, :lab_exam_version)
      sample = Struct.new(:barcode, :material, :collected_at)
      out = Lab::Hl7::Builder.rsp(request: parse("qbp-q11.hl7"), code: "AA", city_slug: "curitiba", query_tag: "T0001", barcode: "1", now: now,
                                  sample: sample.new("1", "So\nro\rPID|1", nil),
                                  items: [ item.new("i", version.new("GLI", Struct.new(:name).new("Gli\r\nPID|1"))) ])
      expect(segments(out).map(&:first)).to eq(%w[MSH MSA QAK QPD SPM ORC OBR])
      expect(Lab::Hl7::Builder.escape("a\nb\r\nc")).to eq("a b c")
    end

    it "I3: MSH-3/MSH-4 voltam como vieram (HD com componentes)" do
      request = Lab::Hl7::Message.parse(oul.sub("|MW-SIM|LAB-MUNICIPAL|") { "|MW^1.2.3^ISO|LAB^9.8^ISO|" })
      out = segments(Lab::Hl7::Builder.ack(request: request, code: "AA", city_slug: "curitiba", now: now))[0]
      expect(out.values_at(4, 5)).to eq([ "MW^1.2.3^ISO", "LAB^9.8^ISO" ])
    end

    it "I4: recusa NUL/controles e segunda mensagem no corpo" do
      expect { Lab::Hl7::Message.parse(oul.sub("98") { "9\x008" }) }.to raise_error(Lab::Hl7::Invalid)
      expect { Lab::Hl7::Message.parse(oul.sub("98") { "9\x078" }) }.to raise_error(Lab::Hl7::Invalid)
      expect { Lab::Hl7::Message.parse(oul + oul) }.to raise_error(Lab::Hl7::Invalid)
      expect { Lab::Hl7::Message.parse(oul + "BHS|^~\\&|x\r") }.to raise_error(Lab::Hl7::Invalid)
    end
  end

  describe "fix round 2" do
    it "L2: código desconhecido não levanta; todo código que a Task 13 emite existe" do
      out = Lab::Hl7::Builder.ack(request: nil, code: "AE", city_slug: "c", now: now, errors: [ error("nao_existe", "OBX^1^3") ])
      expect(segments(out).last[3..]).to eq([ "207^Application internal error^HL70357", "E", "application_error^Erro da aplicacao^99RSL" ])
      emitted = %w[unknown_barcode sample_not_received exam_not_in_version unknown_analyte out_of_entry_range unit_mismatch
                   invalid_value invalid_message unsupported_message_type unsupported_version token_revoked feature_disabled]
      expect(emitted - Lab::Hl7::Builder::ERRORS.keys).to be_empty
    end

    it "L3: OBR/OBX antes do primeiro SPM são recusa com localização" do
      raw = fixture("oul-r22.hl7").sub("SPM|") { "OBR|1|||X^y^99RSL\rOBX|1|NM|a^b^99RSL||1\rSPM|" }
      errors = Lab::Hl7::Message.parse(raw).structure_errors
      expect(errors.map { |e| [ e.code, e.location ] }).to eq([ [ "invalid_message", "OBR^1^1" ], [ "invalid_message", "OBX^1^1" ] ])
    end

    it "L6: QAK-2 OK só com SPM; sem amostra é NF" do
      version = Struct.new(:instrument_test_code, :lab_exam)
      item = Struct.new(:id, :lab_exam_version)
      one = item.new("i", version.new("GLI", Struct.new(:name).new("Glicose")))
      out = Lab::Hl7::Builder.rsp(request: parse("qbp-q11.hl7"), code: "AA", city_slug: "c", query_tag: "T", barcode: "1", now: now, items: [ one ])
      expect(segments(out).map(&:first)).to eq(%w[MSH MSA QAK QPD])
      expect(segments(out)[2][2]).to eq("NF")
    end
  end
end
