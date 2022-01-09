module Network.HTTP.Client

import Network.HTTP.Pool.ConnectionPool
import Network.HTTP.Scheduler
import Network.HTTP.Protocol
import Network.HTTP.Message
import Network.HTTP.Error
import Network.HTTP.Method
import Network.HTTP.Header
import Network.HTTP.URL
import Network.HTTP.Path
import Network.HTTP.Status
import Network.TLS
import Network.TLS.Signature
import Utils.Streaming
import Utils.Bytes
import Data.String
import Data.IORef
import System.File
import System.File.Mode
import Decidable.Equality

public export
record HttpClient e where
  constructor MkHttpClient
  cookie_jar : IORef (List (String, String))
  store_cookie : Bool
  follow_redirect : Bool
  pool_manager : PoolManager e

export
close : {e : _} -> HasIO io => HttpClient e -> io ()
close client = liftIO $ evict_all {m=IO,e=e} $ client.pool_manager

export
new_client : HasIO io => (String -> CertificateCheck IO) -> Nat -> Nat -> Bool -> Bool -> io (HttpClient e)
new_client cert_checker max_total_connection max_per_site_connection store_cookie follow_redirect = do
  manager <- new_pool_manager' max_per_site_connection max_total_connection cert_checker
  jar <- newIORef []
  pure $ MkHttpClient jar store_cookie follow_redirect manager

public export
ResponseHeadersAndBody : Type -> Type
ResponseHeadersAndBody e = Either (Either HttpError e) (HttpResponse, Stream (Of Bits8) IO (Either (Either HttpError e) ()))

replace : Eq a => List (a, b) -> List (a, b) -> List (a, b)
replace original [] = original
replace original ((k, v) :: xs) = replace (loop [] original k v) xs where
  loop : List (a, b) -> List (a, b) -> a -> b -> List (a, b)
  loop acc [] k v = acc
  loop acc ((k', v') :: xs) k v = if k' == k then (k, v) :: (acc <+> xs) else loop ((k', v') :: acc) xs k v

add_if_not_exist : Eq a => (a, b) -> List (a, b) -> List (a, b)
add_if_not_exist (k, v) headers = if any (\(k', v') => k' == k) headers then headers else (k, v) :: headers

export
request' : {e : _} -> HttpClient e -> Method -> URL -> List (String, String) ->
           Nat -> (() -> Stream (Of Bits8) IO (Either e ())) -> IO (ResponseHeadersAndBody e)
request' client method url headers payload_size payload = do
  let Just protocol = protocol_from_str url.protocol
  | Nothing => pure $ Left $ Left (UnknownProtocol url.protocol)

  cookies <- readIORef client.cookie_jar

  let headers_with_missing_info =
        add_if_not_exist ("Host", hostname_string url.host)
        $ add_if_not_exist ("User-Agent", "idris2-http")
        $ add_if_not_exist ("Content-Length", show payload_size)
        $ add_if_not_exist ("Cookie", header_write_value Cookie cookies)
        $ headers

  let message = MkRawHttpMessage method (show url.path <+> url.extensions) headers_with_missing_info
  Right (response, content) <- start_request {m=IO} client.pool_manager protocol message (payload ())
  | Left err => pure $ Left err

  when client.store_cookie $ do
    let Just cookies = lookup_header response.headers Cookie
    | Nothing => pure ()
    modifyIORef client.cookie_jar (\og => replace og cookies)

  if (client.follow_redirect && (Redirection == status_code_class response.status_code.snd))
    then do
      let Just location = lookup_header response.headers Location
      | Nothing => pure (Left $ Left $ MissingHeader "Location")
      request' client method (add url location) headers payload_size payload
    else
      pure $ Right (response, content)

export
request : {e : _} -> HttpClient e -> Method -> URL -> List (String, String) -> List Bits8 -> IO (ResponseHeadersAndBody e)
request  client method url headers payload = request' client method url headers (length payload) (\() => fromList (Right ()) payload)

||| `fputc` in C
%foreign "C:fputc,libc"
export
prim__fputc : Int -> FilePtr -> PrimIO Int

||| `fputc` with higher level primitives in idris2
export
fputc : HasIO io => Bits8 -> File -> io (Either FileError ())
fputc b (FHandle ptr) = do
  let c = cast b
  c' <- primIO $ prim__fputc c ptr
  pure $ if c' == c then Right () else Left FileWriteError

||| Write to a `File` from a `Stream`
export
toFile : HasIO m => File -> Stream (Of Bits8) m r -> m (Either FileError r)
toFile file = build (pure . Right) join $ \(a :> b) => do
  Right () <- fputc a file
    | Left err => pure (Left err)
  b

test : IO ()
test = do
  client <- new_client {e=()} certificate_ignore_check 25 5 True True
  putStrLn "ay"
  Right (response, content) <- request client GET (url' "http://openbsd.org/70.html") [] []
  | Left err => close client *> printLn err
  putStrLn "hi"
  printLn response
  putStrLn "go"
  content <- toList_ content
  close client
  printLn $ ascii_to_string $ content
