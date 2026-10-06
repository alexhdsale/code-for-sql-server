import uuid
from xml.sax.saxutils import escape as E
NS='http://schemas.microsoft.com/sqlserver/reporting/2008/01/reportdefinition'
RD='http://schemas.microsoft.com/SQLServer/reporting/reportdesigner'
FONT='Segoe UI'
names=set()
def tb(name, value, size='8pt', bold=False, color='#1F2937', bg=None, align='Left', vertical=False, italic=False, border=True, fmt=None):
    assert name not in names, name; names.add(name)
    st=[f'<FontFamily>{FONT}</FontFamily>',f'<FontSize>{size}</FontSize>']
    if bold: st.append('<FontWeight>Bold</FontWeight>')
    if italic: st.append('<FontStyle>Italic</FontStyle>')
    if fmt: st.append(f'<Format>{E(fmt)}</Format>')
    st.append(f'<Color>{E(color)}</Color>')
    box=[]
    if border: box.append('<Border><Color>#D1D5DB</Color><Style>Solid</Style></Border>')
    if bg: box.append(f'<BackgroundColor>{E(bg)}</BackgroundColor>')
    box.append('<VerticalAlign>Middle</VerticalAlign>')
    if vertical: box.append('<WritingMode>Vertical</WritingMode>')
    box+= ['<PaddingLeft>3pt</PaddingLeft>','<PaddingRight>3pt</PaddingRight>','<PaddingTop>2pt</PaddingTop>','<PaddingBottom>2pt</PaddingBottom>']
    return (f'<Textbox Name="{name}"><CanGrow>true</CanGrow><KeepTogether>true</KeepTogether>'
            f'<Paragraphs><Paragraph><TextRuns><TextRun><Value>{E(value)}</Value><Style>{"".join(st)}</Style></TextRun></TextRuns>'
            f'<Style><TextAlign>{align}</TextAlign></Style></Paragraph></Paragraphs>'
            f'<rd:DefaultName>{name}</rd:DefaultName><Style>{"".join(box)}</Style></Textbox>')
def fields(cols):
    return '<Fields>'+''.join(f'<Field Name="{c}"><DataField>{c}</DataField><rd:TypeName>{t}</rd:TypeName></Field>' for c,t in cols)+'</Fields>'
S='System.String'; I='System.Int32'; D='System.Decimal'
ds_checks=fields([('database_name',S),('check_code',S),('display_name',S),('sort_order',I),('state',S),('recovery_model',S),('notes',S)])
ds_ret=fields([('database_name',S),('backup_type',S),('status',S),('backup_count',I),('oldest_local',S),('newest_local',S),
               ('retention_days',D),('target_days',I),('gaps',I),('avg_interval',S),('avg_gb',D),('total_gb',D),('source_name',S),('sort_key',I),('files_total',I),('files_24h',I),('files_on_storage',I),('storage_basis',S),('storage_days',I)])
HDR='#1E3A5F'
def cell(tbx): return f'<TablixCell><CellContents>{tbx}</CellContents></TablixCell>'

# ---- Matrix: databases x checks
state_val='=Switch(First(Fields!state.Value)="ON", ChrW(10004), First(Fields!state.Value)="NA", "-", True, "")'
state_bg='=Switch(First(Fields!state.Value)="ON", "#DBEAFE", First(Fields!state.Value)="NA", "#F3F4F6", True, "#FEF3C7")'
matrix=f'''<Tablix Name="MatrixChecks">
<TablixCorner><TablixCornerRows><TablixCornerRow><TablixCornerCell><CellContents>{tb("CornerDatabase","Database",bold=True,color="White",bg=HDR)}</CellContents></TablixCornerCell></TablixCornerRow></TablixCornerRows></TablixCorner>
<TablixBody><TablixColumns><TablixColumn><Width>0.42in</Width></TablixColumn></TablixColumns>
<TablixRows><TablixRow><Height>0.22in</Height><TablixCells>{cell(tb("CheckState",state_val,size="9pt",bold=True,color="#1D4ED8",bg=state_bg,align="Center"))}</TablixCells></TablixRow></TablixRows></TablixBody>
<TablixColumnHierarchy><TablixMembers><TablixMember>
<Group Name="grpCheck"><GroupExpressions><GroupExpression>=Fields!check_code.Value</GroupExpression></GroupExpressions></Group>
<SortExpressions><SortExpression><Value>=Min(Fields!sort_order.Value)</Value></SortExpression></SortExpressions>
<TablixHeader><Size>1.25in</Size><CellContents>{tb("CheckHeader","=First(Fields!display_name.Value)",size="7.5pt",bold=True,color="White",bg=HDR,align="Left",vertical=True)}</CellContents></TablixHeader>
</TablixMember></TablixMembers></TablixColumnHierarchy>
<TablixRowHierarchy><TablixMembers><TablixMember>
<Group Name="grpDatabase"><GroupExpressions><GroupExpression>=Fields!database_name.Value</GroupExpression></GroupExpressions></Group>
<SortExpressions><SortExpression><Value>=Fields!database_name.Value</Value></SortExpression></SortExpressions>
<TablixHeader><Size>1.9in</Size><CellContents>{tb("DatabaseHeader",'=Fields!database_name.Value &amp; " (" &amp; First(Fields!recovery_model.Value) &amp; ")"'.replace("&amp;","&"),bold=True)}</CellContents></TablixHeader>
</TablixMember></TablixMembers></TablixRowHierarchy>
<DataSetName>Checks</DataSetName>
<Filters><Filter><FilterExpression>=Fields!database_name.Value</FilterExpression><Operator>NotEqual</Operator><FilterValues><FilterValue>(server)</FilterValue></FilterValues></Filter></Filters>
<Top>0.75in</Top><Left>0.1in</Left><Height>1.47in</Height><Width>2.32in</Width>
<Style><Border><Style>None</Style></Border></Style>
</Tablix>'''

# ---- Server checks list
srv_val='=IIF(Fields!state.Value="ON", ChrW(10004), "")'
srv_bg='=IIF(Fields!state.Value="ON", "#DBEAFE", "#FEF3C7")'
srv_cols=[('Server-level check','=Fields!display_name.Value','2.2in',None),('Enabled',srv_val,'0.8in',srv_bg),('Notes','=Fields!notes.Value','3in',None)]
def simple_table(name, dataset, cols, top, filt=None, sort=None, prefix=''):
    total_w=sum(float(w[:-2]) for _,_,w,_ in cols)
    colsxml=''.join(f'<TablixColumn><Width>{w}</Width></TablixColumn>' for _,_,w,_ in cols)
    hdr=''.join(cell(tb(f'{prefix}H{i}',h,bold=True,color='White',bg=HDR)) for i,(h,_,_,_) in enumerate(cols))
    det=''.join(cell(tb(f'{prefix}D{i}',v,bg=bg,align='Center' if bg else 'Left')) for i,(_,v,_,bg) in enumerate(cols))
    members=''.join('<TablixMember />' for _ in cols)
    sortx=''
    if sort: sortx='<SortExpressions>'+''.join(f'<SortExpression><Value>{E(s)}</Value></SortExpression>' for s in sort)+'</SortExpressions>'
    filtx=''
    if filt: filtx=f'<Filters><Filter><FilterExpression>{E(filt[0])}</FilterExpression><Operator>{filt[1]}</Operator><FilterValues><FilterValue>{E(filt[2])}</FilterValue></FilterValues></Filter></Filters>'
    return f'''<Tablix Name="{name}"><TablixBody><TablixColumns>{colsxml}</TablixColumns><TablixRows>
<TablixRow><Height>0.25in</Height><TablixCells>{hdr}</TablixCells></TablixRow>
<TablixRow><Height>0.22in</Height><TablixCells>{det}</TablixCells></TablixRow></TablixRows></TablixBody>
<TablixColumnHierarchy><TablixMembers>{members}</TablixMembers></TablixColumnHierarchy>
<TablixRowHierarchy><TablixMembers><TablixMember><KeepWithGroup>After</KeepWithGroup><RepeatOnNewPage>true</RepeatOnNewPage></TablixMember>
<TablixMember><Group Name="{name}_Details" />{sortx}</TablixMember></TablixMembers></TablixRowHierarchy>
<DataSetName>{dataset}</DataSetName>{filtx}<Top>{top}</Top><Left>0.1in</Left><Height>0.47in</Height><Width>{total_w:.2f}in</Width>
<Style><Border><Style>None</Style></Border></Style></Tablix>'''

server_tbl=simple_table('TblServerChecks','Checks',srv_cols,'2.75in',filt=('=Fields!database_name.Value','Equal','(server)'),sort=['=Fields!sort_order.Value'],prefix='Srv')

st_bg='=Switch(Fields!status.Value="OK","#DCFCE7", Fields!status.Value="GAPS","#FEF3C7", Fields!status.Value="N/A","#F3F4F6", Fields!status.Value="OFF","#F3F4F6", True,"#FEE2E2")'
ret_cols=[('Database','=Fields!database_name.Value','1.6in',None),('Type','=Fields!backup_type.Value','0.5in',None),
          ('Status','=Fields!status.Value','0.7in',st_bg),('Count','=Fields!backup_count.Value','0.7in',None),
          ('Oldest','=Fields!oldest_local.Value','1.15in',None),('Newest','=Fields!newest_local.Value','1.15in',None),
          ('Retention d','=Fields!retention_days.Value','0.8in','=IIF(Fields!status.Value="SHORT" OR Fields!status.Value="NONE","#FEE2E2","White")'),
          ('Target d','=Fields!target_days.Value','0.65in',None),('Gaps','=Fields!gaps.Value','0.5in','=IIF(Fields!gaps.Value>0,"#FEF3C7","White")'),
          ('Interval','=Fields!avg_interval.Value','0.75in',None),('Avg GB','=Fields!avg_gb.Value','0.7in',None),
          ('Total GB','=Fields!total_gb.Value','0.75in',None),('Files made','=Fields!files_total.Value','0.75in',None),
          ('Files 24h','=Fields!files_24h.Value','0.65in',None),
          ('On storage','=IIF(IsNothing(Fields!files_on_storage.Value), "n/d", CStr(Fields!files_on_storage.Value))','0.75in',None),
          ('Basis','=Fields!storage_basis.Value','0.9in',None),('Policy d','=Fields!storage_days.Value','0.6in',None),
          ('Source','=Fields!source_name.Value','0.9in',None)]
ret_tbl=simple_table('TblRetention','Retention',ret_cols,'4.1in',sort=['=Fields!sort_key.Value','=Fields!database_name.Value','=Switch(Fields!backup_type.Value="FULL",1, Fields!backup_type.Value="DIFF",2, True,3)'],prefix='Ret')

title=tb('ReportTitle','="MON - what is checked on " & Globals!ReportServerUrl'.replace('Globals!ReportServerUrl','"this server"'),size='14pt',bold=True,color='#0F172A',border=False)
sub=tb('ReportSubtitle','="Edit: OPS.mon.DatabaseCheck (Edit Top 200 Rows) or EXEC OPS.mon.usp_SetCheck.  Blue check = ON, amber = OFF, grey = not applicable.  Generated " & Format(Now(), "yyyy-MM-dd HH:mm")',size='8pt',color='#6B7280',border=False)
h2=tb('ServerTitle','Server-level checks',size='11pt',bold=True,color='#0F172A',border=False)
h3=tb('RetentionTitle','Backup retention and inventory (live: msdb + RDS task history + RDS log metadata; S3 lifecycle not visible)',size='11pt',bold=True,color='#0F172A',border=False)
def pos(tbx,top,left,h,w):
    return tbx.replace('<rd:DefaultName>',f'<Top>{top}</Top><Left>{left}</Left><Height>{h}</Height><Width>{w}</Width><rd:DefaultName>',1)
items=(pos(title,'0.05in','0.1in','0.35in','10in')+pos(sub,'0.4in','0.1in','0.25in','12in')+matrix+
       pos(h2,'2.4in','0.1in','0.3in','6in')+server_tbl+pos(h3,'3.75in','0.1in','0.3in','12in')+ret_tbl)
rdl=f'''<?xml version="1.0" encoding="utf-8"?>
<Report xmlns="{NS}" xmlns:rd="{RD}">
<Description>OPS.mon rev 5.1 - check matrix, server checks, backup retention</Description>
<AutoRefresh>0</AutoRefresh>
<DataSources><DataSource Name="MonServer"><ConnectionProperties><DataProvider>SQL</DataProvider><ConnectString /></ConnectionProperties><rd:DataSourceID>{uuid.uuid4()}</rd:DataSourceID></DataSource></DataSources>
<DataSets>
<DataSet Name="Checks"><Query><DataSourceName>MonServer</DataSourceName><CommandText>EXEC OPS.mon.usp_ReportChecks;</CommandText></Query>{ds_checks}</DataSet>
<DataSet Name="Retention"><Query><DataSourceName>MonServer</DataSourceName><CommandText>EXEC OPS.mon.usp_ReportRetention;</CommandText></Query>{ds_ret}</DataSet>
</DataSets>
<Body><ReportItems>{items}</ReportItems><Height>5in</Height><Style /></Body>
<Width>16.5in</Width>
<Page><PageHeight>8.5in</PageHeight><PageWidth>17.5in</PageWidth><InteractiveHeight>0in</InteractiveHeight><InteractiveWidth>17.5in</InteractiveWidth><LeftMargin>0.3in</LeftMargin><RightMargin>0.3in</RightMargin><TopMargin>0.3in</TopMargin><BottomMargin>0.3in</BottomMargin><Style /></Page>
<Language>en-US</Language>
<ConsumeContainerWhitespace>true</ConsumeContainerWhitespace>
<rd:ReportUnitType>Inch</rd:ReportUnitType>
<rd:ReportID>{uuid.uuid4()}</rd:ReportID>
</Report>'''
import re
scopes=re.findall(r'<(?:DataSet|Tablix|Group) Name="([^"]+)"',rdl)
assert len(scopes)==len(set(scopes)), ('duplicate scope name (rsDuplicateScopeName)', scopes)
open('MON_Checks_and_Retention.rdl','w',encoding='utf-8').write(rdl)
import xml.dom.minidom; xml.dom.minidom.parseString(rdl.encode()); print('well-formed', len(rdl))
