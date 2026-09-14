# Território do Plano 3B: o ator deveria ser um Operator de plataforma
# entrando na cidade por grant. Até lá, o ator é um municipal_admin da própria
# cidade (ACTOR_EMAIL, lido no banco dela) — adaptação mínima do lote 5b.
namespace :channels do
  desc "Rotate a city's WhatsApp access_token. ENV: CITY_SLUG, ROTATE_TOKEN, ACTOR_EMAIL"
  task rotate_token: :environment do
    slug  = ENV.fetch("CITY_SLUG")
    token = ENV.fetch("ROTATE_TOKEN")
    city  = City.find_by!(slug: slug)
    actor = CityConnection.with(city) { User.find_by!(email_address: ENV.fetch("ACTOR_EMAIL")) }

    result = MunicipalityChannels::RotateToken.call(city: city, new_token: token, by: actor)
    abort("[channels:rotate_token] failed: #{result.reason} #{result.message}") if result.failure?
    puts "[channels:rotate_token] rotated channel for #{slug} (phone_number_id=#{result.payload[:channel].phone_number_id})"
  end

  desc "Register a city's WhatsApp channel. ENV: CITY_SLUG, PHONE_NUMBER_ID, WABA_ID, DISPLAY_PHONE_NUMBER, ACCESS_TOKEN"
  task register: :environment do
    city = City.find_by!(slug: ENV.fetch("CITY_SLUG"))
    result = MunicipalityChannels::Register.call(
      city: city, phone_number_id: ENV.fetch("PHONE_NUMBER_ID"), waba_id: ENV.fetch("WABA_ID"),
      display_phone_number: ENV.fetch("DISPLAY_PHONE_NUMBER"), access_token: ENV.fetch("ACCESS_TOKEN")
    )
    abort("[channels:register] failed: #{result.reason} #{result.message}") if result.failure?
    puts "[channels:register] #{city.slug} → phone_number_id=#{result.payload[:channel].phone_number_id}"
  end
end
