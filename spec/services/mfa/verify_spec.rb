require "rails_helper"
require "rotp"

RSpec.describe Mfa::Verify do
  let!(:user) { User.create!(email_address: "carol@example.org", password: "secret123") }
  before { @enroll = Mfa::Enroll.call(user) }

  it "aceita TOTP atual" do
    current = ROTP::TOTP.new(user.otp_secret).now
    expect(described_class.call(user, code: current)).to be true
  end

  it "rejeita código bobo" do
    expect(described_class.call(user, code: "000000")).to be false
  end

  it "consome recovery code (não aceita duas vezes)" do
    code = @enroll[:recovery_codes].first
    expect(described_class.call(user, code: code)).to be true
    expect(described_class.call(user, code: code)).to be false
  end

  # A lista de recovery codes é uma coluna jsonb: consumir um é ler o array,
  # tirar um item e regravar o array inteiro. Sem lock, duas requisições
  # simultâneas partem do MESMO array e a segunda gravação apaga o efeito da
  # primeira — o código que a outra consumiu volta a valer. Duas instâncias
  # carregadas antes de qualquer consumo são exatamente esse par de leituras
  # defasadas, e provam a corrida sem depender de tempo.
  describe "consumo concorrente" do
    let(:codes) { @enroll[:recovery_codes] }

    # Duas leituras do MESMO registro, as duas carregadas antes de qualquer
    # consumo — é o par de requisições simultâneas, sem depender de tempo.
    # (Com `let` preguiçoso a segunda instância nasceria depois da primeira
    # gravação e o teste passaria sem exercitar defasagem nenhuma.)
    def stale_pair
      pair = [ User.find(user.id), User.find(user.id) ]
      pair.each { |u| u.otp_recovery_codes }
      pair
    end

    it "dois códigos diferentes consumidos em paralelo saem os dois da lista" do
      first, second = stale_pair

      expect(described_class.consume_recovery_code(first, codes[0])).to be(true)
      expect(described_class.consume_recovery_code(second, codes[1])).to be(true)

      expect(user.reload.otp_recovery_codes.size).to eq(codes.size - 2)
      expect(described_class.call(user, code: codes[0])).to be(false)
      expect(described_class.call(user, code: codes[1])).to be(false)
    end

    it "o mesmo código em duas leituras defasadas só é consumido uma vez" do
      first, second = stale_pair

      expect(described_class.consume_recovery_code(first, codes[0])).to be(true)

      expect(described_class.consume_recovery_code(second, codes[0])).to be(false)
      expect(user.reload.otp_recovery_codes.size).to eq(codes.size - 1)
    end

    it "com dois códigos restantes, consumir os dois em paralelo zera a lista" do
      user.update!(otp_recovery_codes: user.otp_recovery_codes.first(2))
      first, second = stale_pair

      expect(described_class.consume_recovery_code(first, codes[0])).to be(true)
      expect(described_class.consume_recovery_code(second, codes[1])).to be(true)

      expect(user.reload.otp_recovery_codes).to eq([])
    end
  end
end
