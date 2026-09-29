--  Unit tests. Plain Ada, no framework, non-zero exit on failure.
--  Covers the record format round trip, CRC vectors, log recovery
--  under the device's fault injection, and the store API.

with Ada.Command_Line;
with Ada.Text_IO;           use Ada.Text_IO;
with Legder;                use Legder;
with Legder.Record_Format;  use Legder.Record_Format;
with Legder.RAM_Device;
with Legder.Log;
with Legder.Store;

procedure Tests is

   package Dev renames Legder.RAM_Device;
   package L  is new Legder.Log   (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);
   package KV is new Legder.Store (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);

   Failures : Natural := 0;

   procedure Check (Name : String; Cond : Boolean) is
   begin
      Put_Line ((if Cond then "PASS  " else "FAIL  ") & Name);
      if not Cond then Failures := Failures + 1; end if;
   end Check;

   function K (S : String) return Key is
      R : Key;
   begin
      R.Length := S'Length;
      for I in S'Range loop R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I))); end loop;
      return R;
   end K;

   function V (S : String) return Value is
      R : Value;
   begin
      R.Length := S'Length;
      for I in S'Range loop R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I))); end loop;
      return R;
   end V;

   ---------------------------------------------------------------------

   procedure Test_CRC is
      Empty : constant Byte_Array (1 .. 0) := [];
      Check_Str : constant Byte_Array (1 .. 9) :=
        [16#31#, 16#32#, 16#33#, 16#34#, 16#35#, 16#36#, 16#37#, 16#38#, 16#39#];  --  "123456789"
   begin
      Check ("CRC empty", CRC (Empty) = 0);
      Check ("CRC '123456789' = CBF43926", CRC (Check_Str) = 16#CBF43926#);
   end Test_CRC;

   procedure Test_Record is
      R, D  : Log_Record;
      B     : Block;
      Valid : Boolean;
   begin
      R := (Seq => 42, Kind => Put, K => K ("key"), V => V ("value"));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("round trip valid", Valid);
      Check ("round trip seq",   D.Seq = 42);
      Check ("round trip kind",  D.Kind = Put);
      Check ("round trip key",   D.K = K ("key"));
      Check ("round trip value", Same (D.V, V ("value")));

      B (100) := B (100) xor 1;
      Decode (B, D, Valid);
      Check ("bit flip rejected", not Valid);

      B := [others => 16#FF#];
      Decode (B, D, Valid);
      Check ("erased block rejected", not Valid);

      B := [others => 0];
      Decode (B, D, Valid);
      Check ("zero block rejected", not Valid);

      R := (Seq => 1, Kind => Delete, K => K ("gone"), V => V ("ignored"));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("delete round trip", Valid and then D.Kind = Delete and then D.K = K ("gone"));
      Check ("delete carries no value", D.V.Length = 0);
   end Test_Record;

   procedure Test_Log is
      S  : L.State;
      N  : Natural;
      OK : Boolean;
      Seen : Natural := 0;
      procedure Visit (R : Log_Record) is
      begin
         Seen := Seen + 1;
         if Seen = 2 then
            Check ("scan order: second is b", R.K = K ("b"));
         end if;
      end Visit;
      procedure Scan is new L.Scan (Visit);
   begin
      Dev.Erase;
      L.Open (S, N);
      Check ("empty log opens with 0", N = 0 and S.Head = 0);

      L.Append (S, Put, K ("a"), V ("1"), OK);
      L.Append (S, Put, K ("b"), V ("2"), OK);
      L.Append (S, Put, K ("c"), V ("3"), OK);
      Check ("three appends", OK and S.Head = 3 and S.Last_Seq = 3);
      Check ("one sync per append", Dev.Syncs = 3);

      L.Open (S, N);
      Check ("reopen finds 3", N = 3 and S.Head = 3 and S.Last_Seq = 3);
      Scan (S);
      Check ("scan visits 3", Seen = 3);

      Dev.Tear_Next_Write;
      L.Append (S, Put, K ("d"), V ("4"), OK);
      L.Open (S, N);
      Check ("torn record not recovered", N = 3 and S.Head = 3);

      L.Append (S, Put, K ("e"), V ("5"), OK);
      L.Open (S, N);
      Check ("append after torn overwrites it", N = 4 and S.Last_Seq = 4);

      --  Stale record: an old valid block beyond the head with the
      --  wrong sequence must not be picked up.
      declare
         B : Block;
         R : constant Log_Record := (Seq => 99, Kind => Put, K => K ("stale"), V => V ("x"));
      begin
         Encode (R, B);
         Dev.Write (4, B); Dev.Sync;
      end;
      L.Open (S, N);
      Check ("stale valid block with wrong seq stops recovery", N = 4);
   end Test_Log;

   procedure Test_Store is
      N  : Natural;
      OK : Boolean;
      Got : Value;
      Found : Boolean;
   begin
      Dev.Erase;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         KV.Put (S, K ("x"), V ("1"), OK);
         KV.Put (S, K ("y"), V ("2"), OK);
         KV.Put (S, K ("x"), V ("3"), OK);
         Check ("count after overwrite", KV.Count (S) = 2);
         KV.Delete (S, K ("y"), OK);
         Check ("count after delete", KV.Count (S) = 1);
         KV.Get (S, K ("x"), Got, Found);
         Check ("get latest", Found and then Same (Got, V ("3")));
         KV.Get (S, K ("y"), Got, Found);
         Check ("get deleted", not Found);
      end;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Check ("replayed 4", N = 4);
         KV.Get (S, K ("x"), Got, Found);
         Check ("survives reopen", Found and then Same (Got, V ("3")));
         Check ("count after reopen", KV.Count (S) = 1);
      end;
   end Test_Store;

   procedure Test_Capacity is
      N  : Natural;
      OK : Boolean;
      S  : KV.Store;
      Writes_Before : Natural;
   begin
      Dev.Erase;
      KV.Open (S, N);
      for I in 1 .. KV.Max_Entries loop
         KV.Put (S, K ("k" & I'Image), V ("v"), OK);
         exit when not OK;
      end loop;
      --  Max_Entries = 256 but the RAM device has 256 blocks: the log
      --  fills first. Either way Put reports failure, never raises.
      Writes_Before := Dev.Writes;
      KV.Put (S, K ("one more"), V ("v"), OK);
      Check ("put on full store fails cleanly", not OK);
      Check ("no write on refused put", Dev.Writes = Writes_Before);
   end Test_Capacity;

begin
   Test_CRC;
   Test_Record;
   Test_Log;
   Test_Store;
   Test_Capacity;
   New_Line;
   if Failures = 0 then
      Put_Line ("all tests passed");
   else
      Put_Line (Failures'Image & " failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests;
