require 'json'
require 'action_view/helpers/date_helper'
require 'erubis'

class App < Sinatra::Base
  use Rack::Session::Cookie, expire_after: 2592000, secret: ENV['SECRET']
  use Rack::MethodOverride
  
  set :erb, :escape_html => true
  
  helpers do
    include ActionView::Helpers::DateHelper
    def current_user
      session[:current_user]
    end
  end
  
  def require_login!
    redirect '/' unless current_user
  end
  
  def track(*args)
    MixpanelWorker.perform_async('track', current_user || mixpanel_cookie_id, *args)
  end
  
  def authenticate!
    return false unless params[:payload]
    begin
      payload = JWT.decode(params[:payload], Account.master.secret).first
      session[:current_user] = payload["sub"]
      if payload["signup"] && current_user && mixpanel_cookie_id
        MixpanelWorker.new.perform('alias', current_user, mixpanel_cookie_id)
        track 'Signup'
      else
        track 'Login'
      end
    rescue JWT::DecodeError
      false
    end
  end
  
  def mixpanel_cookie_id
    mp_cookie = request.cookies["mp_#{@token}_mixpanel"]
    if mp_cookie
      mp_env = JSON.parse(mp_cookie)
      mp_env['distinct_id']
    else
      nil
    end
  end
  
  get '/' do
    if current_user || authenticate!
      redirect '/dashboard'
    else
      @skip_header = true
      erb :home
    end
  end
  
  get '/faq' do
    erb :faq
  end
  
  get '/docs' do
    erb :docs
  end
  
  get '/support' do
    erb :support
  end
  
  get '/dashboard' do
    require_login!
    @accounts = Account.where(admins: current_user)
    erb :dashboard
  end
  
  post '/accounts' do
    require_login!
    @account = Account.new(params[:account].merge(admins: [current_user]))
    if @account.save
      @account.track 'Created Account'
      redirect "/accounts/#{@account.id}"
    else
      @account.track 'Validation Error', event: 'Created Account', detail: @account.errors.full_messages
      redirect :back
    end
  end
  
  get '/accounts/:id' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    @authentications = @account.authentications.recent.limit(50)
    @tab = :activity
    erb :account
  end
  
  put '/accounts/:id' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    if @account.update_attributes(params[:account])
      @account.track 'Updated Account'
      redirect "/accounts/#{@account.id}"
    else
      @tab = :settings
      @account.track 'Validation Error', event: 'Updated Account', detail: @account.errors.full_messages
      @error = @account.errors.full_messages.join(", ")
      erb :settings
    end
  end
  
  get '/accounts/:id/billing' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    @tab = :billing
    
    if @account.has_card?
      erb :club_member
    else
      erb :billing
    end
  end
  
  get '/accounts/:id/settings' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    @tab = :settings
    erb :settings
  end
  
  get '/accounts/:id/verify' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    @payload = JWT.decode(params[:payload], @account.secret).first
    erb :verify
  end
  
  post '/accounts/:id/card' do
    require_login!
    @account = Account.where(admins: current_user).find(params[:id])
    
    begin
      if @account.stripe_id?
        customer = Stripe::Customer.retrieve(@account.stripe_id)
        customer.card = params[:card]
        customer.save
        @account.track 'Card Updated'
      else
        customer = Stripe::Customer.create(
          email: current_user,
          description: @account.name,
          card: params[:card]
        )
        @account.track 'Card Captured'
      end

      card = customer.cards.data.first
      @account.update_attributes(stripe_id: customer.id, card_type: card.brand, card_digits: card.last4)
      redirect "/accounts/#{@account.id}/billing"
  
    rescue Stripe::CardError => e
      body = e.json_body
      err  = body[:error]
      @account.track 'Validation Error', action: 'Card Captured', detail: err[:code]
      @error = "<b>Card Issue:</b> #{err[:message]}"
      erb :billing
    rescue Stripe::InvalidRequestError => e
      @error = "There was a problem capturing your card information. Please try again."
      erb :billing
    rescue Stripe::StripeError => e
      @error = "Something went wrong while processing your request. Please <a href='mailto:hello@authmail.co'>contact support</a>."
      erb :billing
    end
  end
  
  post '/login' do
    @skip_header = true
    params.merge! JSON.parse(request.env['rack.input'].read).symbolize_keys if request.content_type == 'application/json'
    @account = Account.find(params[:client_id])
    
    if @account.valid_request?(request)
      @authentication = Authentication.create!(account: @account, email: params[:email], redirect: params[:redirect_uri], state: params[:state])
      @authentication.deliver!
      @account.track 'Authentication Created', email: params[:email]
      erb :login, layout: :bare
    else
      @account.track 'Validation Error', event: 'Authentication Created', detail: @authentication.status_message
      erb :failure, layout: :bare
    end
  end
  
  get '/login/:ref' do
    @skip_header = true
    @authentication = Authentication.where(ref: params[:ref]).first
    @account = @authentication.account
    
    if @authentication.consume!
      @account.track 'Authentication Consumed', email: params[:email]
      redirect @authentication.redirect + "?payload=#{@authentication.payload}"
    else
      @account.track 'Validation Error', event: 'Authentication Consumed', detail: @authentication.status_message
      erb :failure
    end
  end
  
  get '/track/:ref/opened.gif' do
    @authentication = Authentication.where(ref: params[:ref]).first
    @authentication.status!(:opened) if @authentication.try(:status) == 'sent'
    
    @account.track 'Authentication Opened', email: params[:email]
    content_type 'image/gif'
    Base64.decode64 'R0lGODlhAQABAIABAP///wAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='
  end
  
  get '/logout' do
    track 'Logout'
    session.destroy
    redirect '/'
  end
end