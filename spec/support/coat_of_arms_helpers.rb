require "stringio"
require "rack/test"

# Bytes de PNG/UploadedFile para os specs do brasão (só o cabeçalho IHDR basta:
# CoatOfArmsCheck lê assinatura e dimensões).
module CoatOfArmsHelpers
  def coat_png(w, h, pad_to: nil)
    head = "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR".b + [ w, h ].pack("NN") + "\x08\x06\0\0\0".b
    pad_to ? head + ("\0".b * [ pad_to - head.bytesize, 0 ].max) : head
  end

  def coat_upload(bytes, type: "image/png", name: "x.png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)
  end
end
