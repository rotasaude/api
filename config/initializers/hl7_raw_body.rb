# Corpo HL7 nunca passa pela leitura de parâmetros do Rails (I1): com
# application/x-www-form-urlencoded ou JSON, a mensagem inteira (código de
# barras, valores) iria parar nos "Parameters:" do log, antes da autenticação.
# Para POST em /hl7/ guarda o corpo bruto (teto de 1 MB + 1) e o tipo original no
# env e troca o CONTENT_TYPE para text/plain, que o Rails não interpreta.
class Hl7RawBody
  BODY_KEY = "rotasaude.hl7.raw".freeze
  TYPE_KEY = "rotasaude.hl7.content_type".freeze
  LIMIT = 1_048_576 + 1

  def initialize(app) = @app = app

  def call(env)
    if env["PATH_INFO"].to_s.start_with?("/hl7/") && env["REQUEST_METHOD"] == "POST"
      input = env["rack.input"]
      input&.rewind
      raw = input ? input.read(LIMIT).to_s : ""
      env[BODY_KEY] = raw
      env[TYPE_KEY] = env["CONTENT_TYPE"].to_s
      env["rack.input"] = StringIO.new
      env["CONTENT_TYPE"] = "text/plain"
      env["CONTENT_LENGTH"] = "0"
    end
    @app.call(env)
  end
end

Rails.application.config.middleware.insert_before 0, Hl7RawBody
