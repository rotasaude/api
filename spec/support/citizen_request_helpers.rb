# Planta o cookie assinado `citizen_session` de uma sessão real, como
# CitizenAuthentication lê. Não passa pelo OTP.
module CitizenRequestHelpers
  def sign_in_citizen(phone = "+5541998765432")
    session, token = CitizenSession.start!(phone: phone)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:citizen_session] = token
    cookies[:citizen_session] = jar[:citizen_session]
    session
  end

  def json_post(path, params = {})
    post path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" }
  end

  # Módulo 15 (ADR 0027): o par nasce com perfil por POST /citizen/people e a
  # triagem começa pelo nome do protocolo. Devolve o corpo da última resposta
  # (a de /people, se ela falhou).
  def start_citizen_triage(cpf: "529.982.247-25", protocol_name: StartTriage::DEFAULT_PROTOCOL_NAME,
                           birth_date: "1980-05-10", sex: "female", **people_params)
    json_post "/citizen/people", { cpf: cpf, consent_version: "1", birth_date: birth_date, sex: sex }.merge(people_params)
    return JSON.parse(response.body) unless response.successful?

    citizen_id = JSON.parse(response.body).dig("person", "id")
    json_post "/citizen/conversations", citizen_id: citizen_id, consent_version: "1", protocol_name: protocol_name
    JSON.parse(response.body)
  end
end

RSpec.configure { |c| c.include CitizenRequestHelpers, type: :request }
