# spec/services/terminology/import_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §4): importa em transação com status importing,
# ativa no fim (a anterior vira superseded); falha → failed e nada ativo muda.
RSpec.describe Terminology::Import do
  let(:cid10) { Rails.root.join("spec/fixtures/terminology/cid10") }
  let(:ciap2) { Rails.root.join("spec/fixtures/terminology/ciap2") }
  let(:tmp) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(tmp) }

  it "CID-10: categorias e subcategorias, com restrição de sexo; audita a ativação" do
    result = described_class.call(kind: "cid10", version: "2008", path: cid10)

    expect(result).to be_ok
    release = result.payload[:release]
    expect(release).to have_attributes(status: "active", kind: "cid10", version: "2008")
    expect(Cid10Code.where(release: release).pluck(:code)).to contain_exactly("E11", "I10", "O80", "Z01", "E119", "O800", "Z014")
    expect(Cid10Code.find_by!(release: release, code: "O800").sex_restriction).to eq("F")
    expect(result.payload[:counts]).to eq(cid10_codes: 7)
    expect(PlatformEvent.where(name: "terminology.release_activated").map(&:payload))
      .to eq([ { "kind" => "cid10", "version" => "2008" } ])
  end

  it "nova versão substitui a anterior do mesmo kind" do
    first = described_class.call(kind: "ciap2", version: "2", path: ciap2).payload[:release]
    second = described_class.call(kind: "ciap2", version: "2.1", path: ciap2).payload[:release]
    expect(first.reload.status).to eq("superseded")
    expect(second.status).to eq("active")
    expect(TerminologyRelease.active.where(kind: "ciap2").count).to eq(1)
  end

  it "arquivo com código inválido: failed, nenhum código gravado, a ativa continua" do
    active = described_class.call(kind: "ciap2", version: "2", path: ciap2).payload[:release]
    tmp.join("ciap2.csv").write("codigo;titulo\nK86;Hipertensao\nXYZ1;quebrado\n")

    result = described_class.call(kind: "ciap2", version: "3", path: tmp)

    expect(result.reason).to eq(:invalid_file)
    expect(result.message).to include("XYZ1")
    failed = TerminologyRelease.find_by!(kind: "ciap2", version: "3")
    expect(failed.status).to eq("failed")
    expect(Ciap2Code.where(release: failed)).to be_empty
    expect(active.reload.status).to eq("active")
  end

  it "recusa kind, versão e caminho inválidos sem criar release" do
    expect(described_class.call(kind: "cbo", version: "1", path: ciap2).reason).to eq(:unknown_kind)
    expect(described_class.call(kind: "sigtap", version: "2026-10", path: ciap2).reason).to eq(:invalid_version)
    expect(described_class.call(kind: "sigtap", version: "202613", path: ciap2).reason).to eq(:invalid_version)
    expect(described_class.call(kind: "ciap2", version: "2", path: tmp.join("nada")).reason).to eq(:file_not_found)
    expect(TerminologyRelease.count).to eq(0)
  end

it "ZIP corrompido no meio da leitura: failed, invalid_file, a ativa continua" do
  active = described_class.call(kind: "ciap2", version: "2", path: ciap2).payload[:release]
  path = tmp.join("corrompido.zip")
  Zip::File.open(path.to_s, create: true) { |z| z.get_output_stream("ciap2.csv") { |o| o.write("codigo;titulo\n" + "K86;Hipertensao\n" * 500) } }
  bytes = path.binread
  bytes[60, 40] = "\x00" * 40
  path.binwrite(bytes)

  result = described_class.call(kind: "ciap2", version: "3", path: path)

  expect(result.reason).to eq(:invalid_file)
  expect(TerminologyRelease.find_by!(kind: "ciap2", version: "3").status).to eq("failed")
  expect(active.reload.status).to eq("active")
end

it "linha longa demais: failed e invalid_file" do
  tmp.join("ciap2.csv").write("codigo;titulo\nK86;" + ("a" * (OfficialArchive::MAX_LINE_BYTES + 10)))
  result = described_class.call(kind: "ciap2", version: "3", path: tmp)
  expect(result.reason).to eq(:invalid_file)
  expect(TerminologyRelease.find_by!(kind: "ciap2", version: "3").status).to eq("failed")
end

it "erro inesperado também marca failed, sem ser mascarado por falha ao marcar" do
  allow_any_instance_of(Terminology::Ciap2Reader).to receive(:write).and_raise(IOError, "disco")
  result = described_class.call(kind: "ciap2", version: "3", path: ciap2)
  expect(result.reason).to eq(:invalid_file)
  expect(result.message).to include("disco")
  expect(TerminologyRelease.find_by!(kind: "ciap2", version: "3").status).to eq("failed")
end
end
