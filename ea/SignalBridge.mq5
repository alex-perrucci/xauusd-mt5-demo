#property strict
#property version   "1.00"
#property description "XAUUSD demo-only GitHub signal executor"

#define SIGNAL_FILE        "xauusd\\signal.txt"
#define GUARD_FILE         "xauusd\\guard.txt"
#define ACK_FILE           "xauusd\\ack.txt"
#define LAST_SIGNAL_FILE   "xauusd\\last_signal.txt"
#define ABS_MAX_RISK_PCT   0.5
#define ABS_MIN_RR         2.0

struct GuardConfig
  {
   long   expected_login;
   string expected_server;
   string broker_symbol;
   double max_spread_points;
   double max_risk_pct;
   double min_rr;
   ulong  magic;
   ulong  deviation_points;
  };

struct BridgeSignal
  {
   int      schema;
   string   id;
   string   action;
   string   logical_symbol;
   bool     has_sl;
   double   sl;
   bool     has_tp;
   double   tp;
   double   risk_pct;
   long     created_epoch;
   long     valid_epoch;
  };

string g_last_signal_id="";

int OnInit()
  {
   g_last_signal_id=ReadSmallFile(LAST_SIGNAL_FILE);
   EventSetTimer(1);
   Print("SignalBridge initialized. Data path=",TerminalInfoString(TERMINAL_DATA_PATH));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   ProcessBridge();
  }

string ReadSmallFile(const string file_name)
  {
   int h=FileOpen(file_name,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return "";
   string value=FileReadString(h);
   FileClose(h);
   return value;
  }

bool WriteSmallFile(const string file_name,const string value)
  {
   int h=FileOpen(file_name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return false;
   FileWriteString(h,value+"\r\n");
   FileFlush(h);
   FileClose(h);
   return true;
  }

void Acknowledge(const string id,const string status,const string message)
  {
   string safe_message=message;
   StringReplace(safe_message,"|","/");
   StringReplace(safe_message,"\r"," ");
   StringReplace(safe_message,"\n"," ");
   string line=id+"|"+status+"|"+IntegerToString((int)TimeCurrent())+"|"+safe_message;
   WriteSmallFile(ACK_FILE,line);
  }

void FinishSignal(const string id,const string status,const string message)
  {
   g_last_signal_id=id;
   WriteSmallFile(LAST_SIGNAL_FILE,id);
   Acknowledge(id,status,message);
   Print("signal ",id," -> ",status,": ",message);
  }

bool LoadGuard(GuardConfig &guard,string &error)
  {
   string line=ReadSmallFile(GUARD_FILE);
   if(line=="")
     {
      error="guard file missing or empty";
      return false;
     }

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=9 || f[0]!="1")
     {
      error="invalid guard format";
      return false;
     }

   guard.expected_login=(long)StringToInteger(f[1]);
   guard.expected_server=f[2];
   guard.broker_symbol=f[3];
   guard.max_spread_points=StringToDouble(f[4]);
   guard.max_risk_pct=MathMin(StringToDouble(f[5]),ABS_MAX_RISK_PCT);
   guard.min_rr=MathMax(StringToDouble(f[6]),ABS_MIN_RR);
   guard.magic=(ulong)StringToInteger(f[7]);
   guard.deviation_points=(ulong)StringToInteger(f[8]);

   if(guard.expected_login<=0 || guard.expected_server=="" || guard.broker_symbol=="")
     {
      error="guard account/server/symbol is incomplete";
      return false;
     }
   if(guard.max_spread_points<=0 || guard.max_risk_pct<=0 || guard.magic==0)
     {
      error="guard risk/spread/magic is invalid";
      return false;
     }
   return true;
  }

bool LoadSignal(BridgeSignal &signal,string &error)
  {
   string line=ReadSmallFile(SIGNAL_FILE);
   if(line=="")
      return false;

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=9)
     {
      error="invalid signal field count";
      return false;
     }

   signal.schema=(int)StringToInteger(f[0]);
   signal.id=f[1];
   signal.action=f[2];
   signal.logical_symbol=f[3];
   signal.has_sl=(f[4]!="");
   signal.sl=signal.has_sl ? StringToDouble(f[4]) : 0.0;
   signal.has_tp=(f[5]!="");
   signal.tp=signal.has_tp ? StringToDouble(f[5]) : 0.0;
   signal.risk_pct=StringToDouble(f[6]);
   signal.created_epoch=(long)StringToInteger(f[7]);
   signal.valid_epoch=(long)StringToInteger(f[8]);

   if(signal.schema!=1 || signal.id=="" || signal.logical_symbol!="XAUUSD")
     {
      error="invalid schema/id/logical symbol";
      return false;
     }
   return true;
  }

bool IsKnownAction(const string action)
  {
   return action=="NO_TRADE" || action=="HOLD" || action=="BUY" || action=="SELL" || action=="CLOSE" || action=="MODIFY";
  }

bool CheckAccountGuard(const GuardConfig &guard,string &error)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      error="terminal not connected";
      return false;
     }
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
     {
      error="account is not DEMO";
      return false;
     }
   if((long)AccountInfoInteger(ACCOUNT_LOGIN)!=guard.expected_login)
     {
      error="unexpected account login";
      return false;
     }
   if(AccountInfoString(ACCOUNT_SERVER)!=guard.expected_server)
     {
      error="unexpected account server";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      error="automated trading is disabled";
      return false;
     }
   return true;
  }

int VolumeDigits(const double step)
  {
   int digits=0;
   double scaled=step;
   while(digits<8 && MathAbs(scaled-MathRound(scaled))>1e-9)
     {
      scaled*=10.0;
      digits++;
     }
   return digits;
  }

double NormalizeRiskVolume(const string symbol,const ENUM_ORDER_TYPE order_type,const double entry,const double sl,const double risk_pct,string &error)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount=equity*(risk_pct/100.0);
   if(equity<=0 || risk_amount<=0)
     {
      error="invalid equity/risk amount";
      return 0.0;
     }

   double one_lot_profit=0.0;
   if(!OrderCalcProfit(order_type,symbol,1.0,entry,sl,one_lot_profit))
     {
      error="OrderCalcProfit failed";
      return 0.0;
     }
   double one_lot_loss=MathAbs(one_lot_profit);
   if(one_lot_loss<=0)
     {
      error="one-lot SL loss is zero";
      return 0.0;
     }

   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0 || vmax<=0 || step<=0)
     {
      error="invalid broker volume constraints";
      return 0.0;
     }

   double raw=risk_amount/one_lot_loss;
   if(raw<vmin)
     {
      error="required volume below broker minimum; refusing to exceed risk cap";
      return 0.0;
     }

   double volume=MathFloor((MathMin(raw,vmax)+1e-12)/step)*step;
   volume=NormalizeDouble(volume,VolumeDigits(step));

   double actual_profit=0.0;
   if(volume<=0 || !OrderCalcProfit(order_type,symbol,volume,entry,sl,actual_profit))
     {
      error="volume risk verification failed";
      return 0.0;
     }
   if(MathAbs(actual_profit)>risk_amount*1.01)
     {
      error="normalized volume exceeds risk cap";
      return 0.0;
     }
   return volume;
  }

ENUM_ORDER_TYPE_FILLING FillingMode(const string symbol)
  {
   long filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   long execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
   if((filling & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if(execution!=SYMBOL_TRADE_EXECUTION_MARKET)
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
  }

bool HasAnySymbolPosition(const string symbol)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol)
         return true;
     }
   return false;
  }

bool IsManagedPosition(const string symbol,const ulong magic)
  {
   return PositionGetString(POSITION_SYMBOL)==symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==magic;
  }

bool SendChecked(MqlTradeRequest &request,MqlTradeResult &result,string &message)
  {
   MqlTradeCheckResult check={};
   ResetLastError();
   if(!OrderCheck(request,check))
     {
      message="OrderCheck failed: "+check.comment+" err="+IntegerToString(GetLastError());
      return false;
     }

   ResetLastError();
   if(!OrderSend(request,result))
     {
      message="OrderSend failed: err="+IntegerToString(GetLastError());
      return false;
     }

   if(result.retcode!=TRADE_RETCODE_DONE && result.retcode!=TRADE_RETCODE_PLACED && result.retcode!=TRADE_RETCODE_DONE_PARTIAL)
     {
      message="trade rejected retcode="+IntegerToString((int)result.retcode)+" "+result.comment;
      return false;
     }
   message="retcode="+IntegerToString((int)result.retcode)+" deal="+(string)result.deal+" order="+(string)result.order;
   return true;
  }

bool OpenPosition(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(!SymbolSelect(symbol,true))
     {
      message="broker symbol unavailable";
      return false;
     }
   if(HasAnySymbolPosition(symbol))
     {
      message="existing broker-symbol position; stacking blocked";
      return false;
     }
   if(!signal.has_sl || !signal.has_tp || signal.sl<=0 || signal.tp<=0)
     {
      message="SL and TP are mandatory";
      return false;
     }
   if(signal.risk_pct<=0 || signal.risk_pct>guard.max_risk_pct || signal.risk_pct>ABS_MAX_RISK_PCT)
     {
      message="risk exceeds local cap";
      return false;
     }

   MqlTick tick={};
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
     {
      message="no live tick";
      return false;
     }
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0)
     {
      message="invalid point size";
      return false;
     }
   double spread=(tick.ask-tick.bid)/point;
   if(spread>guard.max_spread_points)
     {
      message="spread too high: "+DoubleToString(spread,1);
      return false;
     }

   bool is_buy=(signal.action=="BUY");
   ENUM_ORDER_TYPE type=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry=is_buy ? tick.ask : tick.bid;
   double risk_distance=is_buy ? entry-signal.sl : signal.sl-entry;
   double reward_distance=is_buy ? signal.tp-entry : entry-signal.tp;
   if(risk_distance<=0 || reward_distance<=0)
     {
      message="invalid SL/entry/TP geometry";
      return false;
     }
   double rr=reward_distance/risk_distance;
   if(rr<guard.min_rr || rr<ABS_MIN_RR)
     {
      message="live RR below minimum: "+DoubleToString(rr,2);
      return false;
     }

   string error="";
   double volume=NormalizeRiskVolume(symbol,type,entry,signal.sl,signal.risk_pct,error);
   if(volume<=0)
     {
      message=error;
      return false;
     }

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.symbol=symbol;
   request.volume=volume;
   request.type=type;
   request.price=NormalizeDouble(entry,digits);
   request.sl=NormalizeDouble(signal.sl,digits);
   request.tp=NormalizeDouble(signal.tp,digits);
   request.deviation=guard.deviation_points;
   request.magic=guard.magic;
   request.comment="cgpt-demo:"+StringSubstr(signal.id,0,12);
   request.type_time=ORDER_TIME_GTC;
   request.type_filling=FillingMode(symbol);

   return SendChecked(request,result,message);
  }

bool CloseManaged(const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      found=true;
      MqlTick tick={};
      if(!SymbolInfoTick(symbol,tick))
        {
         message="no tick while closing";
         return false;
        }
      long position_type=PositionGetInteger(POSITION_TYPE);
      double volume=PositionGetDouble(POSITION_VOLUME);
      ENUM_ORDER_TYPE type=(position_type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_DEAL;
      request.position=ticket;
      request.symbol=symbol;
      request.volume=volume;
      request.type=type;
      request.price=(type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
      request.deviation=guard.deviation_points;
      request.magic=guard.magic;
      request.comment="cgpt-close";
      request.type_time=ORDER_TIME_GTC;
      request.type_filling=FillingMode(symbol);
      if(!SendChecked(request,result,message))
         return false;
     }
   if(!found)
      message="no managed position open";
   else
      message="managed position(s) closed";
   return true;
  }

bool ModifyManaged(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      found=true;
      MqlTick tick={};
      if(!SymbolInfoTick(symbol,tick))
        {
         message="no tick while modifying";
         return false;
        }
      long position_type=PositionGetInteger(POSITION_TYPE);
      double sl=signal.has_sl ? signal.sl : PositionGetDouble(POSITION_SL);
      double tp=signal.has_tp ? signal.tp : PositionGetDouble(POSITION_TP);
      if(position_type==POSITION_TYPE_BUY)
        {
         if((sl>0 && sl>=tick.bid) || (tp>0 && tp<=tick.bid))
           {
            message="invalid BUY SL/TP modification";
            return false;
           }
        }
      else
        {
         if((sl>0 && sl<=tick.ask) || (tp>0 && tp>=tick.ask))
           {
            message="invalid SELL SL/TP modification";
            return false;
           }
        }

      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_SLTP;
      request.position=ticket;
      request.symbol=symbol;
      request.sl=sl>0 ? NormalizeDouble(sl,digits) : 0.0;
      request.tp=tp>0 ? NormalizeDouble(tp,digits) : 0.0;
      request.magic=guard.magic;
      if(!SendChecked(request,result,message))
         return false;
     }
   if(!found)
     {
      message="no managed position to modify";
      return false;
     }
   message="managed position modified";
   return true;
  }

void ProcessBridge()
  {
   BridgeSignal signal={};
   string error="";
   if(!LoadSignal(signal,error))
      return;
   if(signal.id==g_last_signal_id)
      return;

   if(!IsKnownAction(signal.action))
     {
      FinishSignal(signal.id,"BLOCKED","unknown action");
      return;
     }
   if(signal.valid_epoch<=0 || (long)TimeCurrent()>signal.valid_epoch)
     {
      FinishSignal(signal.id,"BLOCKED","signal expired");
      return;
     }
   if(signal.action=="NO_TRADE" || signal.action=="HOLD")
     {
      FinishSignal(signal.id,"OK",signal.action+" acknowledged");
      return;
     }

   GuardConfig guard={};
   if(!LoadGuard(guard,error))
     {
      Print("guard unavailable: ",error);
      return;
     }
   if(!CheckAccountGuard(guard,error))
     {
      if(error=="terminal not connected" || error=="automated trading is disabled")
        {
         Print("waiting: ",error);
         return;
        }
      FinishSignal(signal.id,"BLOCKED",error);
      return;
     }

   string message="";
   bool ok=false;
   if(signal.action=="BUY" || signal.action=="SELL")
      ok=OpenPosition(signal,guard,message);
   else if(signal.action=="CLOSE")
      ok=CloseManaged(guard,message);
   else if(signal.action=="MODIFY")
      ok=ModifyManaged(signal,guard,message);

   FinishSignal(signal.id,ok ? "OK" : "BLOCKED",message);
  }
