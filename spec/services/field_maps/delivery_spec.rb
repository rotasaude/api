require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.1, Q34): o plano de entrega do arquivo de
# mapa — inteiro, um intervalo, não modificado ou intervalo impossível — a
# partir dos cabeçalhos da requisição, sem tocar o arquivo.
RSpec.describe FieldMaps::Delivery, type: :model do
  SIZE = 1000
  let(:sha) { "ab" * 32 }
  let(:map) { FieldMap.new(sha256: sha, size_bytes: SIZE, storage_key: "field-maps/cities/x/2026-11-01-abababababab.pmtiles") }

  def plan(range: nil, if_none_match: nil, if_range: nil) = described_class.plan(map: map, range: range, if_none_match: if_none_match, if_range: if_range)
  def summary(result) = [ result.status, result.offset, result.length, result.headers["Content-Range"] ]

  it "sem Range → 200 inteiro, com os cabeçalhos fixos" do
    result = plan
    expect(summary(result)).to eq([ 200, 0, SIZE, nil ])
    expect(result.headers).to include("ETag" => %("#{sha}"), "Accept-Ranges" => "bytes", "Content-Type" => "application/vnd.pmtiles",
                                      "Cache-Control" => "private, no-cache", "Content-Length" => SIZE.to_s)
  end

  it "um intervalo: começo-fim, começo aberto, sufixo e fim além do tamanho" do
    expect(summary(plan(range: "bytes=0-"))).to eq([ 206, 0, SIZE, "bytes 0-999/1000" ])
    expect(summary(plan(range: "bytes=100-199"))).to eq([ 206, 100, 100, "bytes 100-199/1000" ])
    expect(summary(plan(range: "bytes=-500"))).to eq([ 206, 500, 500, "bytes 500-999/1000" ])
    expect(summary(plan(range: "bytes=-5000"))).to eq([ 206, 0, SIZE, "bytes 0-999/1000" ])
    expect(summary(plan(range: "bytes=900-5000"))).to eq([ 206, 900, 100, "bytes 900-999/1000" ])
    expect(summary(plan(range: "bytes=999-999"))).to eq([ 206, 999, 1, "bytes 999-999/1000" ])
    expect(plan(range: "bytes=100-199").headers).to include("Content-Length" => "100", "ETag" => %("#{sha}"))
  end

  it "intervalo impossível → 416 com bytes */tamanho" do
    [ "bytes=5-2", "bytes=1000-", "bytes=1000-2000", "bytes=-0", "bytes=-", "bytes=abc", "bytes=1-x" ].each do |range|
      result = plan(range: range)
      expect(summary(result)).to eq([ 416, 0, 0, "bytes */1000" ]), range
      expect(result.headers).to include("Accept-Ranges" => "bytes")
    end
  end

  it "mais de um intervalo, ou unidade que não é bytes → 200 inteiro" do
    expect(summary(plan(range: "bytes=0-1,5-6"))).to eq([ 200, 0, SIZE, nil ])
    expect(summary(plan(range: "items=0-1"))).to eq([ 200, 0, SIZE, nil ])
  end

  it "If-None-Match com o ETag (com aspas, sem, fraco, em lista ou *) → 304; outro → segue" do
    [ %("#{sha}"), sha, %(W/"#{sha}"), %("outro", "#{sha}"), "*" ].each do |value|
      result = plan(if_none_match: value, range: "bytes=0-9")
      expect(summary(result)).to eq([ 304, 0, 0, nil ]), value
      expect(result.headers).to include("ETag" => %("#{sha}"))
      expect(result.headers).not_to have_key("Content-Length")
    end
    expect(plan(if_none_match: %("#{'cd' * 32}")).status).to eq(200)
  end

  it "If-Range igual ao ETag honra o Range; diferente devolve o arquivo inteiro (Q34)" do
    expect(summary(plan(range: "bytes=100-", if_range: %("#{sha}")))).to eq([ 206, 100, 900, "bytes 100-999/1000" ])
    expect(summary(plan(range: "bytes=100-", if_range: %("#{'cd' * 32}")))).to eq([ 200, 0, SIZE, nil ])
    expect(summary(plan(range: "bytes=100-", if_range: "Sat, 14 Nov 2026 12:00:00 GMT"))).to eq([ 200, 0, SIZE, nil ])
  end

  describe FieldMaps::Delivery::Body do
    it "rende o intervalo em pedaços, lendo só o que foi pedido" do
      key = "field-maps/cities/#{SecureRandom.uuid}/body.pmtiles"
      FieldMaps::Storage.upload(key, FieldMapHelpers::FIELD_MAP_FIXTURE)
      bytes = field_map_bytes
      stub_const("FieldSync::Catalog::MAP_CHUNK", 300_000)
      allow(FieldMaps::Storage).to receive(:chunk).and_call_original

      parts = described_class.new(key, 10, bytes.bytesize - 10).to_enum(:each).to_a
      expect(parts.map(&:bytesize)).to eq([ 300_000, 300_000, 300_000, bytes.bytesize - 10 - 900_000 ])
      expect(parts.join).to eq(bytes.byteslice(10..))
      expect(described_class.new(key, 0, 7).to_enum(:each).to_a).to eq([ "PMTiles".b ])
      expect(FieldMaps::Storage).to have_received(:chunk).with(key, 0..6)
      expect(described_class.new(key, 0, 0).to_enum(:each).to_a).to eq([])
    ensure
      FieldMaps::Storage.delete(key)
    end
  end
end
