require "rails_helper"
require "stringio"

# Brasão é validado pelos bytes, nunca pelo content-type declarado pelo cliente.
RSpec.describe CityIdentity::CoatOfArmsCheck do
  def check(bytes) = described_class.call(StringIO.new(bytes.b))

  def pad(bytes, pad_to) = pad_to ? bytes + ("\0".b * [ pad_to - bytes.bytesize, 0 ].max) : bytes

  def png(w, h, pad_to: nil)
    head = "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR".b + [ w, h ].pack("NN") + "\x08\x06\0\0\0".b
    pad(head, pad_to)
  end

  def riff(fourcc, payload)
    "RIFF".b + [ 4 + 8 + payload.bytesize ].pack("V") + "WEBP".b + fourcc.b + [ payload.bytesize ].pack("V") + payload
  end

  def le24(n) = [ n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff ].pack("C3")

  def webp_vp8x(w, h) = riff("VP8X", "\0\0\0\0".b + le24(w - 1) + le24(h - 1))

  def webp_vp8l(w, h)
    bits = (w - 1) | ((h - 1) << 14)
    riff("VP8L", "\x2f".b + [ bits ].pack("V"))
  end

  def webp_vp8(w, h)
    riff("VP8 ", "\0\0\0".b + "\x9d\x01\x2a".b + [ w, h ].pack("vv"))
  end

  it("aceita PNG 512x512") { expect(check(png(512, 512)).payload).to include(content_type: "image/png", width: 512, height: 512) }

  it "aceita os três WebP" do
    [ webp_vp8x(300, 200), webp_vp8l(300, 200), webp_vp8(300, 200) ].each do |b|
      expect(check(b).payload).to include(content_type: "image/webp", width: 300, height: 200)
    end
  end

  it("informa o tamanho em bytes") { expect(check(png(512, 512, pad_to: 1000)).payload[:byte_size]).to eq(1000) }
  it("recusa acima de 262_144 bytes") { expect(check(png(512, 512, pad_to: 262_145)).reason).to eq(:too_large) }
  it("aceita exatamente 262_144 bytes") { expect(check(png(512, 512, pad_to: 262_144))).to be_ok }
  it("recusa lado menor < 128") { expect(check(png(127, 400)).reason).to eq(:invalid_dimensions) }
  it("recusa lado maior > 1024") { expect(check(png(200, 1025)).reason).to eq(:invalid_dimensions) }
  it("aceita os limites 128 e 1024") { expect(check(png(128, 1024))).to be_ok }

  it "recusa SVG, HTML e GIF, mesmo que se digam PNG" do
    [ '<svg xmlns="http://www.w3.org/2000/svg"/>', "<html><script>x</script>", "GIF89a" + "\0" * 20 ].each do |s|
      expect(check(s).reason).to eq(:invalid_format)
    end
  end

  it("recusa PNG truncado") { expect(check(png(512, 512)[0, 20]).reason).to eq(:invalid_format) }
  it("recusa vazio") { expect(check("").reason).to eq(:invalid_format) }
end
